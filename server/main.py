#!/usr/bin/env python

import os
import logging

from datetime import datetime, timedelta
from google.appengine.ext.webapp import template
from google.appengine.api import users
from google.appengine.ext import db
from google.appengine.ext import webapp
from google.appengine.ext.webapp.util import run_wsgi_app

from yslib.dates import time_delta_in_words, delta_to_seconds

template_path = os.path.join(os.path.dirname(__file__), 'templates')
template.register_template_library('myfilters')

def prepare_stuff(f):
  def wrapper(self, *args, **kwargs):
    if not self.prepare():
      return
    return f(self, *args, **kwargs)
  wrapper.__name__ = f.__name__
  wrapper.__dict__ = f.__dict__
  wrapper.__doc__  = f.__doc__
  return wrapper

def login_required(f):
  def wrapper(self, *args, **kwargs):
    user = users.get_current_user()
    if user == None:
      self.redirect(users.create_login_url(self.request.uri))
      return
    return f(self, *args, **kwargs)
  wrapper.__name__ = f.__name__
  wrapper.__dict__ = f.__dict__
  wrapper.__doc__  = f.__doc__
  return wrapper

def must_be_admin(f):
  def wrapper(self, *args, **kwargs):
    user = users.get_current_user()
    if user == None:
      self.redirect(users.create_login_url(self.request.uri))
      return
    if not users.is_current_user_admin():
      self.redirect('/server-admin-required')
      return
    return f(self, *args, **kwargs)
  wrapper.__name__ = f.__name__
  wrapper.__dict__ = f.__dict__
  wrapper.__doc__  = f.__doc__
  return wrapper

class InstallationConfig(db.Model):
  server_name = db.TextProperty()
  builder_poll_interval = db.IntegerProperty(default = 60)
  builder_offline_after = db.IntegerProperty(default = 120)
  builder_is_recent_within = db.IntegerProperty(default = 60*60*24)
  num_latest_builds = db.IntegerProperty(default = 3)
  num_recent_builds = db.IntegerProperty(default = 20)

config_query = InstallationConfig.gql("LIMIT 1")

class Project(db.Model):
  name = db.StringProperty()
  permalink = db.StringProperty()
  owner = db.UserProperty()
  created_at = db.DateTimeProperty(auto_now_add=True)
  script = db.TextProperty()
  
  def validate(self):  
    self.name = self.name.strip()
    errors = dict()
    if len(self.name) == 0:
      errors.update(name = "project name is required")
    if len(self.permalink) == 0:
      errors.update(permalink = "project permalink is required")
    return errors
    
  def urlname(self):
    return "%s" % self.permalink
    
  @staticmethod
  def by_urlname(permalink):
    return Project.all().filter('permalink =', permalink).get()    

class Builder(db.Model):
  name = db.StringProperty()
  created_at = db.DateTimeProperty(auto_now_add = True)
  last_check_at = db.DateTimeProperty()
  busy = db.BooleanProperty()
  progress = db.TextProperty()
  
  def bind_environment(self, config, now):
    self._since_last_check = delta_to_seconds(now - self.last_check_at)
    self._config = config
    
  def set_message_count(self, count):
    self._message_count = count
    
  def message_count(self):
    return self._message_count
  
  def since_last_check(self):
    return self._since_last_check
  
  def is_online(self):
    return self._since_last_check < self._config.builder_offline_after
    
def split_tags(s):
  if s == '-':
    return []
  else:
    return s.split(',')
    
class Build(db.Model):
  project = db.ReferenceProperty(Project, collection_name = 'builds')
  builder = db.ReferenceProperty(Builder, collection_name = 'builds')
  version = db.StringProperty()
  report = db.TextProperty(default = '')
  created_at = db.DateTimeProperty(auto_now_add = True)
  created_by = db.UserProperty()
  
  def calculate_derived_data(self):
    stores = dict()
    items = dict()
    last_item = None
    last_item_in_store = None
    for line in self.report.split("\n"):
      if len(line) == 0:
        continue
      command, args = line.split("\t", 1)
      if command == 'STORE':
        name, tags, description, rem = (args+"\t\t").split("\t", 3)
        if description == '-' or description == '':
          description = name
        stores[name] = dict(name = name, tags = split_tags(tags), description = description, items = [])
      elif command == 'ITEM':
        kind, name, tags, description, rem = (args+"\t").split("\t", 4)
        tags = split_tags(tags)
        if kind != 'file' or not 'featured' in tags:
          # skip this item
          last_item_in_store = last_item = None
          continue
        if description == '-':
          description = name
        last_item = items[name] = dict(kind=kind, name=name, tags=tags, description=description)
      elif command == 'INSTORE':
        if last_item == None:
          continue
        name, rem = (args+"\t").split("\t", 1)
        store = stores[name]
        if not 'public' in store['tags']:
          last_item_in_store = None
          continue
        last_item_in_store = dict(other_locations = [], **last_item)
        store['items'].append(last_item_in_store)
      elif command == 'ACCESS':
        if last_item_in_store == None:
          continue
        kind, tags, path, rem = (args+"\t").split("\t", 3)
        location = dict(kind=kind, tags=split_tags(tags), path=path)
        if kind == 'url' and not last_item.has_key('url_location'):
          last_item_in_store['url_location'] = location
        else:
          last_item_in_store['other_locations'].append(location)

    self._stores = stores.values()
    self._stores = filter(lambda store: len(store['items']) > 0, self._stores)
    
  def calculate_time_deltas(self, now):
    self._since_start = (now - self.created_at)
    
  def stores(self):
    return self._stores
    
  def since_start(self):
    return self._since_start
    
  def urlname(self):
    return self.version
    
class Message(db.Model):
  builder = db.ReferenceProperty(Builder, collection_name = 'messages')
  build = db.ReferenceProperty(Build, collection_name = 'messages')
  created_at = db.DateTimeProperty(auto_now_add = True)
  body = db.TextProperty()
  state = db.IntegerProperty(default = 0)

class BaseHandler(webapp.RequestHandler):
  def __init__(self):
    self.config = config_query.get()
    self.data = dict()
    
  def prepare(self):
    self.now = datetime.now()
    self.data.update(now = self.now)
    
    if self.config == None:
      self.redirect('/server-config')
      return False
      
    self.fill_in_user()
    self.data.update(server_name = self.config.server_name)
      
    return True    
    
  def render(self, *path_components):
    self.response.out.write(template.render(os.path.join(template_path, *path_components), self.data))
    
  def fill_in_user(self):
    self.user = users.get_current_user()
    if self.user == None:
      self.data.update(user = None, login_url = users.create_login_url(self.request.uri),
        user_is_server_admin = False)
    else:
      self.data.update(user = self.user.nickname(), logout_url = users.create_logout_url(self.request.uri),
        user_is_server_admin = users.is_current_user_admin())
    
  def fetch_active_builders(self):
    result = Builder.all().filter('last_check_at > ', (self.now - timedelta(seconds=self.config.builder_is_recent_within))).fetch(20)
    for builder in result:
      count = builder.messages.filter('state =', 0).count(limit = 10)
      logging.info("count for builder %s: %d" % (builder.name, count))
      builder.set_message_count(count)
    return result
    
class ProjectsHandler(BaseHandler):
  @prepare_stuff
  def get(self):
    projects = Project.gql("ORDER BY name")
    self.data.update(projects = projects)
    self.render('projects', 'list.html')

class IndexHandler(BaseHandler):
  def get(self):
    self.redirect('projects')

class CreateProjectHandler(BaseHandler):
  @prepare_stuff
  def get(self):
    project = Project()
    self.render_editor(project)          
    
  @prepare_stuff
  def post(self):
    project = Project()
    if self.user:
      project.owner = self.user
    project.name = self.request.get('project_name')
    project.script = self.request.get('project_script')
    project.permalink = self.request.get('project_permalink')
    
    errors = project.validate()
    if len(errors) == 0:
      project.put()
      self.redirect('/')
    else:       
      self.render_editor(project, errors)          
      
  def render_editor(self, project, errors = dict()):
    self.data.update(errors = errors, edit = False, project = project)
    self.render('project', 'editor.html')

class EditProjectHandler(BaseHandler):
  @prepare_stuff
  def get(self, project_key):
    project = Project.by_urlname(project_key)
    if project == None:
      self.error(404)
      return
    self.render_editor(project)          

  @prepare_stuff
  def post(self, project_key):
    project = Project.by_urlname(project_key)
    if project == None:
      self.error(404)
      return
    project.name = self.request.get('project_name')
    project.script = self.request.get('project_script')
    project.permalink = self.request.get('project_permalink')

    errors = project.validate()
    if len(errors) == 0:
      project.put()
      self.redirect('/projects/%s' % project.urlname())
    else:       
      self.render_editor(project, errors)          

  def render_editor(self, project, errors = dict()):
    self.data.update(errors = errors, edit = True, project = project)
    self.render('project', 'editor.html')

class DeleteProjectHandler(BaseHandler):
  @prepare_stuff
  def post(self, project_key):
    project = Project.by_urlname(project_key)
    if project == None:
      self.error(404)
      return
    confirm = self.request.get('confirm')
    if confirm != '1':
      self.redirect('/projects/%s/edit' % project.urlname())
      return

    project.delete()
    self.redirect('/projects')

class ProjectHandler(BaseHandler):
  
  @prepare_stuff
  def get(self, project_key):
    project = Project.by_urlname(project_key)
    if project == None:
      self.error(404)
      return
    
    builders = self.fetch_active_builders()
    for builder in builders:
      builder.bind_environment(self.config, self.now)
    online_builders = [b for b in builders if b.is_online()]
    recent_builders = [b for b in builders if not b.is_online()]
    
    num_latest = self.config.num_latest_builds
    num_recent = self.config.num_recent_builds
    builds = project.builds.order('-created_at').fetch(num_latest + num_recent)
    for build in builds:
      build.calculate_time_deltas(self.now)
    
    latest_builds = builds[0:num_latest]
    recent_builds = builds[num_latest:num_latest+num_recent]
    for build in latest_builds:
      build.calculate_derived_data()

    # calculate next version
    next_version = '0.0.1'
    if len(builds) > 0:
      v = builds[0].version.split('.')
      v[-1] = str(int(v[-1]) + 1)
      next_version = ".".join(v)
    
    self.data.update(
      project = project,
      online_builders = online_builders,
      recent_builders = recent_builders,
      builders = online_builders + recent_builders,
      latest_builds = latest_builds,
      recent_builds = recent_builds,
      num_latest_builds = num_latest,
      num_recent_builds = num_recent,
      next_version = next_version,
    )
    self.render('project', 'index.html')

class ProjectBuildHandler(BaseHandler):
  @prepare_stuff
  def get(self, project_key, build_key):
    project = Project.by_urlname(project_key)
    if project == None:
      logging.warning("BuildHandler: project '%s' not found" % project_key)
      self.error(404)
      return
    build = project.builds.filter('version =', build_key).order('-created_at').get()
    if build == None:
      logging.warning("BuildHandler: build '%s' not found in project '%s'" % (build_key, project_key))
      self.error(404)
      return

    build.calculate_time_deltas(self.now)
    build.calculate_derived_data()

    self.data.update(
      project = project,
      build = build,
    )
    self.render('project', 'buildinfo.html')

class BuildProjectHandler(BaseHandler):
  @prepare_stuff
  def post(self, project_key):
    project = Project.by_urlname(project_key)
    if project == None:
      self.error(404)
      return
    builder = Builder.all().filter('name = ', self.request.get('builder')).get()
    if builder == None:
      logging.warning("BuildProjectHandler: attemp to build %s using a non-existent builder %s" % (project.name, self.request.get('builder')))
      self.error(500)
      return
    version = self.request.get('version')
    if version == None or len(version) == 0:
      logging.warning("BuildProjectHandler: version is not specified")
      self.error(500)
      return
      
    build = Build(project = project, version = version, builder = builder, created_by = self.user)
    build.put()

    body = "SET\tver\t%s\nPROJECT\t%s\t%s\n%s" % (version, project.permalink, project.name, project.script)
    
    message = Message(builder = builder, build = build, body = body)
    message.put()
    
    self.redirect('/projects/%s' % project.urlname())

class BuilderObtainWorkHandler(BaseHandler):
  def get(self):
    self.post()
    
  @prepare_stuff
  def post(self, name):
    if name == None or len(name) == 0:
      self.error(501)
      return

    message = None
    builder = Builder.all().filter('name = ', name).get()
    if builder == None:
      builder = Builder(name = name)
    else:
      # handle stale messages
      stale_messages = builder.messages.filter('state =', 1).filter('created_at <', (self.now - timedelta(seconds = 60*60))).order('created_at').fetch(100)
      for message in stale_messages:
        message.state = 3
        message.put()
    
      # retrieve the next message to process
      message = builder.messages.filter('state =', 0).order('created_at').get()
      
    if message == None:
      self.response.out.write("IDLE\tv1\t%d" % self.config.builder_poll_interval)
      builder.busy = False
    else:
      message.state = 1
      message.put()
      builder.busy = True
      body = "ENVELOPE\tv1\t%s\n%s" % (message.key(), message.body)
      self.response.out.write(body)
      
    builder.last_check_at = datetime.now()
    builder.put()

class BuilderMessageDoneHandler(BaseHandler):
  @prepare_stuff
  def post(self, name, message_key):
    builder = Builder.all().filter('name = ', name).get()
    if builder == None:
      self.error(404)
      return
      
    report = self.request.get('report')
    if report == None:
      logging.warning("message done handler is called with empty report")
      report = ''

    builder.last_check_at = datetime.now()
    builder.put()
    
    message = Message.get(message_key)
    if message == None:
      logging.warning("BuilderMessageDoneHandler: no message found with key %s" % message_key)
      self.error(500)
      return
    if message.builder.key() != builder.key():
      logging.warning("BuilderMessageDoneHandler: wrong builder - %s instead of %s" % (message.builder.key(), builder.key()))
      self.error(500)
      return

    message.state = 2
    message.put()
    
    build = message.build
    build.report = report
    build.put()

class ServerConfigHandler(BaseHandler):
  @must_be_admin
  def get(self):
    config = config_query.get()
    if config == None:
      config = InstallationConfig(server_name = 'Untitled AppHome')
    self.show_editor(config)
    
  def show_editor(self, config):      
    self.fill_in_user()
    self.data.update(config = config)
    self.render('server-config', 'editor.html')
    
  @must_be_admin
  def post(self):
    config = config_query.get()
    if config == None:
      config = InstallationConfig()
      
    if self.request.get('delete'):
      if config.is_saved():
        config.delete()
      self.redirect('/')
      return
      
    config.server_name = db.Text(self.request.get('server_name'))
    config.builder_poll_interval = int(self.request.get('builder_poll_interval'))
    config.builder_offline_after = int(self.request.get('builder_offline_after'))
    config.builder_is_recent_within = int(self.request.get('builder_is_recent_within'))
    config.num_latest_builds = int(self.request.get('num_latest_builds'))
    config.num_recent_builds = int(self.request.get('num_recent_builds'))
    if len(config.server_name) == 0:
      self.render(config)
      return
      
    config.put()
    self.redirect('/')
    
class ServerAdminRequiredHandler(BaseHandler):
  @login_required
  def get(self):
    self.fill_in_user()
    self.render('server-admin-required.html')

url_mapping = [
  ('/', IndexHandler),
  ('/projects', ProjectsHandler),
  ('/projects/create', CreateProjectHandler),
  ('/projects/([^/]*)', ProjectHandler),
  ('/projects/([^/]*)/edit', EditProjectHandler),
  ('/projects/([^/]*)/delete', DeleteProjectHandler),
  ('/projects/([^/]*)/build', BuildProjectHandler),
  ('/projects/([^/]*)/builds/([^/]*)', ProjectBuildHandler),
  
  ('/builders/([^/]*)/obtain-work', BuilderObtainWorkHandler),
  ('/builders/([^/]*)/messages/([^/]*)/done', BuilderMessageDoneHandler),
  ('/server-config', ServerConfigHandler),
  ('/server-admin-required', ServerAdminRequiredHandler)
]
application = webapp.WSGIApplication(url_mapping, debug=True)

def main():
  run_wsgi_app(application)

if __name__ == '__main__':
  main()
