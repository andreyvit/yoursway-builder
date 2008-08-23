#!/usr/bin/env python

import os
from google.appengine.ext.webapp import template
from google.appengine.api import users
from google.appengine.ext import db
from google.appengine.ext import webapp
from google.appengine.ext.webapp.util import run_wsgi_app

template_path = os.path.join(os.path.dirname(__file__), 'templates')

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

config_query = InstallationConfig.gql("LIMIT 1")

class Project(db.Model):
  name = db.StringProperty()
  owner = db.UserProperty()
  created_at = db.DateTimeProperty(auto_now_add=True)
  
  def validate(self):  
    self.name = self.name.strip()
    errors = dict()
    if len(self.name) == 0:
      errors.update(name = "project name is required")
    return errors

class Greeting(db.Model):
  author = db.UserProperty()
  content = db.StringProperty(multiline=True)
  date = db.DateTimeProperty(auto_now_add=True)

class BaseHandler(webapp.RequestHandler):
  def __init__(self):
    self.config = config_query.get()
    self.data = dict()
    
  def prepare(self):
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
    
    errors = project.validate()
    if len(errors) == 0:
      project.put()
      self.redirect('/')
    else:       
      self.render_editor(project, errors)          
      
  def render_editor(self, project, errors = dict()):
    self.data.update(errors = errors, project = project)
    self.render('projects', 'editor.html')

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
  ('/server-config', ServerConfigHandler),
  ('/server-admin-required', ServerAdminRequiredHandler)
]
application = webapp.WSGIApplication(url_mapping, debug=True)

def main():
  run_wsgi_app(application)

if __name__ == '__main__':
  main()
