#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os
import logging
import cgi

from datetime import datetime, timedelta
from google.appengine.ext.webapp import template
from google.appengine.api import users
from google.appengine.ext import db
from google.appengine.ext import webapp
from google.appengine.ext.webapp.util import run_wsgi_app
from appengine_utilities.flash import Flash

from yslib.dates import time_delta_in_words, delta_to_seconds

template_path = os.path.join(os.path.dirname(__file__), 'templates')
template.register_template_library('myfilters')

class InstallationConfig(db.Model):
  server_name = db.TextProperty(default = 'YourSway Builder')
  builder_poll_interval = db.IntegerProperty(default = 60)
  builder_offline_after = db.IntegerProperty(default = 120)
  builder_is_recent_within = db.IntegerProperty(default = 60*60*24)
  num_latest_builds = db.IntegerProperty(default = 3)
  num_recent_builds = db.IntegerProperty(default = 30)

config_query = InstallationConfig.gql("LIMIT 1")

ANONYMOUS_LEVEL = -1
VIEWER_LEVEL    = 0
NORMAL_LEVEL    = 1
ADMIN_LEVEL     = 2
GOD_LEVEL       = 3

level_names = {
  ANONYMOUS_LEVEL: 'guest',
  VIEWER_LEVEL: 'viewer',
  NORMAL_LEVEL: 'normal',
  ADMIN_LEVEL: 'admin',
  GOD_LEVEL: 'developer'
}

class Account(db.Model):
  user = db.UserProperty()
  email = db.EmailProperty()
  level = db.IntegerProperty(default = NORMAL_LEVEL, choices = [ANONYMOUS_LEVEL, VIEWER_LEVEL, NORMAL_LEVEL, ADMIN_LEVEL, GOD_LEVEL])
  
  def level_name(self):
    return level_names[self.level]
    
  def urlname(self):
    return self.email

class Project(db.Model):
  name = db.StringProperty()
  permalink = db.StringProperty()
  owner = db.UserProperty()
  created_at = db.DateTimeProperty(auto_now_add=True)
  is_public = db.BooleanProperty(default = False)
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
    
BUILD_ABANDONED = 0
BUILD_SUCCEEDED = 1
BUILD_FAILED = 2
BUILD_INPROGRESS = 3
    
state_info = {
  BUILD_ABANDONED:  dict(name = 'abandoned',  color = 'grey'),
  BUILD_INPROGRESS: dict(name = 'inprogress', color = 'blue'),
  BUILD_FAILED:     dict(name = 'failed',     color = 'red'),
  BUILD_SUCCEEDED:    dict(name = 'succeeded',  color = 'green'),
}

class Build(db.Model):
  project = db.ReferenceProperty(Project, collection_name = 'builds')
  builder = db.ReferenceProperty(Builder, collection_name = 'builds')
  state = db.IntegerProperty(default = BUILD_ABANDONED, choices = [BUILD_INPROGRESS, BUILD_SUCCEEDED, BUILD_FAILED, BUILD_ABANDONED])
  version = db.StringProperty()
  report = db.TextProperty(default = '')
  failure_reason = db.TextProperty(default = '')
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
    
  def state_name(self):
    return state_info[self.state]['name']

  def state_color(self):
    return state_info[self.state]['color']
    
  def failure_reason_summary(self):
    if len(self.failure_reason) == 0:
      return "(unknown failure reason)"
    return self.failure_reason.split("\n", 1)[0]
    
class Message(db.Model):
  builder = db.ReferenceProperty(Builder, collection_name = 'messages')
  build = db.ReferenceProperty(Build, collection_name = 'messages')
  created_at = db.DateTimeProperty(auto_now_add = True)
  body = db.TextProperty()
  state = db.IntegerProperty(default = 0)

class FinishRequest(Exception):
  pass

class prolog(object):
  def __init__(decor, path_components = [], fetch = [], config_needed = True, required_level = ANONYMOUS_LEVEL):
    decor.config_needed = config_needed
    decor.required_level = required_level
    decor.path_components = path_components
    decor.fetch = fetch
    pass

  def __call__(decor, original_func):
    def decoration(self, *args):
      try:
        self.read_config(config_needed = decor.config_needed)
        self.read_user()
        self.effective_level = self.account.level
        for func, arg in zip(decor.path_components, args):
          getattr(self, 'fetch_%s' % func)(arg)
        if self.effective_level < decor.required_level:
          self.access_denied()
        for func in decor.fetch:
          getattr(self, 'also_fetch_%s' % func)()
        self.elaborate_permissions_for_template()
        return original_func(self, *args)
      except FinishRequest:
        pass
    decoration.__name__ = original_func.__name__
    decoration.__dict__ = original_func.__dict__
    decoration.__doc__  = original_func.__doc__
    return decoration

class BaseHandler(webapp.RequestHandler):
  def __init__(self):
    self.config = None
    self.now = datetime.now()
    self._flash = Flash()
    self.data = dict(now = self.now, flash = self._flash.msg)
    
  def flash(self, message):
    self._flash.msg = message
    
  def read_config(self, config_needed = True):
    self.config = config_query.get()
    if self.config == None:
      if config_needed:
        self.redirect_and_finish('/server-config',
          flash = "Please review the default configuration before the first use")
      else:
        self.config = InstallationConfig()
    self.data.update(config = self.config, server_name = self.config.server_name)
        
  def read_user(self):
    self.user = users.get_current_user()
    if self.user == None:
      self.account = Account(user = None, email = None, level = ANONYMOUS_LEVEL)
      self.data.update(username = None, login_url = users.create_login_url(self.request.uri))
    else:
      self.account = (Account.all().filter('user =', self.user).get() or
        Account.all().filter('email =', self.user.email()).get() or
        Account(user = self.user, email = self.user.email(), level = ANONYMOUS_LEVEL))
      if users.is_current_user_admin() and self.account.level < GOD_LEVEL:
        # propagate new admins to gods
        self.account.level = GOD_LEVEL
        self.account.put()
      elif not users.is_current_user_admin() and self.account.level == GOD_LEVEL:
        # revoke god priveledges from ex-admins
        self.account.level = ADMIN_LEVEL
        self.account.put()
      if self.account.email == None:
        self.account.email = self.user.email()
        self.account.put()
      if self.account.user == None:
        self.account.user = self.user
        self.account.put()
      self.data.update(username = self.user.nickname(), logout_url = users.create_logout_url(self.request.uri))
    self.data.update(account = self.account)
    
  def elaborate_permissions_for_template(self):
    self.data.update(
      at_least_viewer = (self.effective_level >= VIEWER_LEVEL),
      at_least_normal = (self.effective_level >= NORMAL_LEVEL),
      at_least_admin = (self.effective_level >= ADMIN_LEVEL),
    )

  def redirect_and_finish(self, url, flash = None):
    if flash:
      self.flash(flash)
    self.redirect(url)
    raise FinishRequest
    
  def render_and_finish(self, *path_components):
    self.response.out.write(template.render(os.path.join(template_path, *path_components), self.data))
    raise FinishRequest
    
  def access_denied(self, message = None):
    if self.user == None and self.request.method == 'GET':
      self.redirect_and_finish(users.create_login_url(self.request.uri))
    self.die(403, 'access_denied.html', message=message)

  def not_found(self, message = None):
    self.die(404, 'not_found.html', message=message)

  def invalid_request(self, message = None):
    self.die(400, 'invalid_request.html', message=message)
    
  def die(self, code, template, message = None):
    if message:
      logging.warning("%d: %s" % (code, message))
    self.error(code)
    self.data.update(message = message)
    self.render_and_finish('errors', template)
    
  def fetch_active_builders(self):
    result = Builder.all().filter('last_check_at > ', (self.now - timedelta(seconds=self.config.builder_is_recent_within))).fetch(20)
    for builder in result:
      count = builder.messages.filter('state =', 0).count(limit = 10)
      logging.info("count for builder %s: %d" % (builder.name, count))
      builder.set_message_count(count)
    return result
    
  def also_fetch_projects(self):
    self.projects = Project.all().order('name').fetch(1000)
    if self.effective_level < VIEWER_LEVEL:
      self.projects = filter(lambda p : p.is_public, self.projects)
    self.data.update(projects = self.projects)
    
  def fetch_project(self, project_component):
    if project_component == 'new':
      self.project = Project()
    else:
      self.project = Project.by_urlname(project_component)
    if self.project == None:
      self.not_found("Project ‘%s’ does not exist" % project_component)
    if not self.project.is_public and self.effective_level < VIEWER_LEVEL:
      self.access_denied("Access denied to project ‘%s’" % project_component)
    self.data.update(project = self.project)
    
  def fetch_build(self, build_component):
    self.build = self.project.builds.filter('version =', build_component).order('-created_at').get()
    if self.build == None:
      self.not_found("Build '%s' not found in project '%s'" % (build_component, self.project.name))
    self.data.update(build = self.build)
    
  def fetch_builder(self, builder_component):
    self.builder = Builder.all().filter('name = ', builder_component).get()
    if self.builder == None:
      self.builder = Builder(name = builder_component)
    self.data.update(builder = self.builder)
    
  def also_fetch_builder(self):
    self.builder = Builder.all().filter('name = ', self.request.get('builder')).get()
    if self.builder == None:
      self.not_found("Builder ‘%s’ not found" % self.request.get('builder'))
    self.data.update(builder = self.builder)
    
  def also_fetch_people(self):
    self.people = Account.all().fetch(1000)
    self.data.update(people = self.people)
    
  def fetch_person(self, person_component):
    person_component = person_component.replace('%40', '@')
    if person_component == 'new' or person_component == 'invite':
      self.person = Account(level = ANONYMOUS_LEVEL)
    else:
      self.person = Account.all().filter('email =', person_component).get()
      if self.person == None:
        self.not_found("No user account exists for email address “%s”" % person_component)
    self.data.update(person = self.person)
    
class ProjectsHandler(BaseHandler):
  @prolog(fetch = ['projects'])
  def get(self):
    self.render_and_finish('projects', 'list.html')

class IndexHandler(BaseHandler):
  def get(self):
    self.redirect('projects')

class CreateEditProjectHandler(BaseHandler):
  @prolog(path_components = ['project'], required_level = ADMIN_LEVEL)
  def get(self, project_key):
    self.render_editor()          

  @prolog(path_components = ['project'], required_level = ADMIN_LEVEL)
  def post(self, project_key):
    if not self.project.is_saved():
      self.project.owner = self.user
    self.project.name = self.request.get('project_name')
    self.project.script = self.request.get('project_script')
    self.project.permalink = self.request.get('project_permalink')

    errors = self.project.validate()
    if len(errors) == 0:
      self.project.put()
      self.redirect('/projects/%s' % self.project.urlname())
    else:       
      self.render_editor(errors)          

  def render_editor(self, errors = dict()):
    self.data.update(errors = errors, edit = self.project.is_saved())
    self.render_and_finish('project', 'editor.html')

class PeopleHandler(BaseHandler):
  @prolog(fetch = ['people'], required_level = ADMIN_LEVEL)
  def get(self):
    self.render_and_finish('people', 'index.html')

class CrudePersonHandler(BaseHandler):
  @prolog(path_components = ['person'], required_level = ADMIN_LEVEL)
  def get(self, project_key):
    self.render_editor()

  @prolog(path_components = ['person'], required_level = ADMIN_LEVEL)
  def post(self, project_key):
    if self.person.is_saved and self.request.get('delete'):
      if self.request.get('confirm'):
        self.person.delete()
        self.redirect_and_finish('/people',
          flash = "%s is deleted." % self.person.email)
      else:
        self.redirect_and_finish(self.request.uri,
          flash = "Please confirm deletion by checking the box.")
      
    if not self.person.is_saved():
      self.person.invited_by = self.user
    self.person.email = self.request.get('email')
    self.person.level = int(self.request.get('level'))

    # errors = self.person.validate()
    # if len(errors) == 0:
    self.person.put()
    self.redirect_and_finish('/people',
      flash = ("%s saved." if self.person.is_saved() else "%s added.") % self.person.email)
    # else:
    #   self.render_editor(errors)

  def render_editor(self, errors = dict()):
    self.data.update(errors = errors, edit = self.person.is_saved())
    self.render_and_finish('people', 'invite.html')

class DeleteProjectHandler(BaseHandler):
  @prolog(path_components = ['project'], required_level = ADMIN_LEVEL)
  def post(self, project_key):
    confirm = self.request.get('confirm')
    if confirm != '1':
      self.redirect('/projects/%s/edit' % self.project.urlname())
      return

    self.project.delete()
    self.redirect('/projects')

class ProjectHandler(BaseHandler):
  
  @prolog(path_components = ['project'])
  def get(self, project_key):
    if self.effective_level > VIEWER_LEVEL:
      builders = self.fetch_active_builders()
      for builder in builders:
        builder.bind_environment(self.config, self.now)
      online_builders = [b for b in builders if b.is_online()]
      recent_builders = [b for b in builders if not b.is_online()]
      self.data.update(online_builders = online_builders, recent_builders = recent_builders,
        builders = online_builders + recent_builders)
    
    num_latest = self.config.num_latest_builds
    num_recent = self.config.num_recent_builds
    builds = self.project.builds.order('-created_at').fetch(max(num_latest, num_recent))
    for build in builds:
      build.calculate_time_deltas(self.now)
    
    latest_builds = builds[0:num_latest]
    recent_builds = builds[0:num_recent]
    for build in latest_builds:
      build.calculate_derived_data()

    # calculate next version
    next_version = '0.0.1'
    if len(builds) > 0:
      v = builds[0].version.split('.')
      v[-1] = str(int(v[-1]) + 1)
      next_version = ".".join(v)
    
    self.data.update(
      latest_builds = latest_builds,
      recent_builds = recent_builds,
      num_latest_builds = num_latest,
      num_recent_builds = num_recent,
      next_version = next_version,
    )
    self.render_and_finish('project', 'index.html')

class ProjectBuildHandler(BaseHandler):
  @prolog(path_components = ['project', 'build'])
  def get(self, project_key, build_key):
    self.build.calculate_time_deltas(self.now)
    self.build.calculate_derived_data()
    self.render_and_finish('project', 'buildinfo.html')

class BuildProjectHandler(BaseHandler):
  @prolog(path_components = ['project'], fetch = ['builder'], required_level = NORMAL_LEVEL)
  def post(self, project_key):
    version = self.request.get('version')
    if version == None or len(version) == 0:
      logging.warning("BuildProjectHandler: version is not specified")
      self.error(500)
      return
      
    existing_count = self.project.builds.filter('version =', version).count()
    if existing_count > 0:
      logging.info("Ignoring build request with the same version number (%s, project %s)" % (version, self.project.name))
      self.redirect_and_finish('/projects/%s' % self.project.urlname(),
        flash = "Version %s already exists. Please pick another." % version)
      
    build = Build(project = self.project, version = version, builder = self.builder, created_by = self.user,
      state = BUILD_INPROGRESS)
    build.put()

    body = "SET\tver\t%s\nPROJECT\t%s\t%s\n%s" % (version, self.project.permalink, self.project.name, self.project.script)
    
    message = Message(builder = self.builder, build = build, body = body)
    message.put()
    
    self.redirect_and_finish('/projects/%s' % self.project.urlname(),
      flash = "Started bulding version %s. Please refresh this page to track status." % version)

class BuilderObtainWorkHandler(BaseHandler):
  def get(self):
    self.post()
    
  @prolog(path_components = ['builder'])
  def post(self, name):
    message = None
    if self.builder.is_saved():
      # handle stale messages
      stale_messages = self.builder.messages.filter('state =', 1).filter('created_at <', (self.now - timedelta(seconds = 60*60))).order('created_at').fetch(100)
      for message in stale_messages:
        message.state = 3
        message.put()
    
      # retrieve the next message to process
      message = self.builder.messages.filter('state =', 0).order('created_at').get()
      
    if message == None:
      self.response.out.write("IDLE\tv1\t%d" % self.config.builder_poll_interval)
      self.builder.busy = False
    else:
      message.state = 1
      message.put()
      self.builder.busy = True
      body = "ENVELOPE\tv1\t%s\n%s" % (message.key(), message.body)
      self.response.out.write(body)
      
    self.builder.last_check_at = datetime.now()
    self.builder.put()

class BuilderMessageDoneHandler(BaseHandler):
  @prolog(path_components = ['builder'])
  def post(self, name, message_key):
    report = self.request.get('report')
    if report == None:
      logging.warning("message done handler is called with empty report")
      report = ''

    self.builder.last_check_at = datetime.now()
    self.builder.put()
    
    message = Message.get(message_key)
    if message == None:
      self.not_found("No message found with key %s" % message_key)
    if message.builder.key() != self.builder.key():
      self.invalid_request("The chosen message %s belongs to another builder" % message_key)

    message.state = 2
    message.put()
    
    build = message.build
    build.report = report
    
    outcome = self.request.get("outcome")
    if outcome == 'ERR':
      build.state = BUILD_FAILED
      build.failure_reason = self.request.get("failure_reason")
    elif outcome == 'SUCCESS':
      build.state = BUILD_SUCCEEDED
    else:
      build.state = BUILD_ABANDONED
    build.put()

class ServerConfigHandler(BaseHandler):
  @prolog(config_needed = False, required_level = ADMIN_LEVEL)
  def get(self):
    self.show_editor()
    
  @prolog(config_needed = False, required_level = ADMIN_LEVEL)
  def post(self):
    if self.request.get('delete'):
      if self.config.is_saved():
        self.config.delete()
      self.redirect('/')
      return
      
    self.config.server_name = db.Text(self.request.get('server_name'))
    self.config.builder_poll_interval = int(self.request.get('builder_poll_interval'))
    self.config.builder_offline_after = int(self.request.get('builder_offline_after'))
    self.config.builder_is_recent_within = int(self.request.get('builder_is_recent_within'))
    self.config.num_latest_builds = int(self.request.get('num_latest_builds'))
    self.config.num_recent_builds = int(self.request.get('num_recent_builds'))
    if len(self.config.server_name) == 0:
      self.show_editor()
      
    self.config.put()
    self.redirect('/')

  def show_editor(self):      
    self.render_and_finish('server-config', 'editor.html')
    
url_mapping = [
  ('/', IndexHandler),
  ('/people', PeopleHandler),
  ('/people/(invite)', CrudePersonHandler),
  ('/people/([^/]*)', CrudePersonHandler),
  ('/projects', ProjectsHandler),
  ('/projects/(new)', CreateEditProjectHandler),
  ('/projects/([^/]*)', ProjectHandler),
  ('/projects/([^/]*)/edit', CreateEditProjectHandler),
  ('/projects/([^/]*)/delete', DeleteProjectHandler),
  ('/projects/([^/]*)/build', BuildProjectHandler),
  ('/projects/([^/]*)/builds/([^/]*)', ProjectBuildHandler),
  
  ('/builders/([^/]*)/obtain-work', BuilderObtainWorkHandler),
  ('/builders/([^/]*)/messages/([^/]*)/done', BuilderMessageDoneHandler),
  ('/server-config', ServerConfigHandler),
]
application = webapp.WSGIApplication(url_mapping, debug=True)

def main():
  run_wsgi_app(application)

if __name__ == '__main__':
  main()
