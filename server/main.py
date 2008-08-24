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

config_query = InstallationConfig.gql("LIMIT 1")

class Project(db.Model):
  name = db.StringProperty()
  owner = db.UserProperty()
  created_at = db.DateTimeProperty(auto_now_add=True)
  script = db.TextProperty()
  
  def validate(self):  
    self.name = self.name.strip()
    errors = dict()
    if len(self.name) == 0:
      errors.update(name = "project name is required")
    return errors
    
  def urlname(self):
    return "%s" % (self.key(),)
    
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
    
class Message(db.Model):
  builder = db.ReferenceProperty(Builder, collection_name = 'messages')
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
      count = builder.messages.count(limit = 10)
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
    project = Project.get(project_key)
    self.render_editor(project)          

  @prepare_stuff
  def post(self, project_key):
    project = Project.get(project_key)
    project.name = self.request.get('project_name')

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
    project = Project.get(project_key)
    confirm = self.request.get('confirm')
    if confirm != '1':
      self.redirect('/projects/%s/edit' % project.urlname())
      return

    project.delete()
    self.redirect('/projects')

class ProjectHandler(BaseHandler):
  @prepare_stuff
  def get(self, project_key):
    project = Project.get(project_key)
    builders = self.fetch_active_builders()
    for builder in builders:
      builder.bind_environment(self.config, self.now)
    online_builders = [b for b in builders if b.is_online()]
    recent_builders = [b for b in builders if not b.is_online()]
    self.data.update(
      project = project,
      online_builders = online_builders,
      recent_builders = recent_builders,
      builders = online_builders + recent_builders,
    )
    self.render('project', 'index.html')

class BuildProjectHandler(BaseHandler):
  @prepare_stuff
  def post(self, project_key):
    project = Project.get(project_key)
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

    body = "SET\tver\t%s\n%s" % (version, project.script)
    
    message = Message(builder = builder, body = body)
    message.put()
    
    self.redirect('/projects/%s' % project.urlname())

class ObtainWorkHandler(BaseHandler):
  def get(self):
    self.post()
    
  @prepare_stuff
  def post(self):
    name = self.request.get('name')
    if name == None or len(name) == 0:
      self.error(501)
      return
    builder = Builder.all().filter('name = ', name).get()
    if builder == None:
      builder = Builder(name = name)
    builder.last_check_at = datetime.now()
    builder.put()
    self.response.out.write("SETPOLL\t%d" % self.config.builder_poll_interval)

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
  
  ('/builders/obtain-work', ObtainWorkHandler),
  ('/server-config', ServerConfigHandler),
  ('/server-admin-required', ServerAdminRequiredHandler)
]
application = webapp.WSGIApplication(url_mapping, debug=True)

def main():
  run_wsgi_app(application)

if __name__ == '__main__':
  main()
