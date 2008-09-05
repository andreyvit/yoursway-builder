# -*- coding: utf-8 -*-

import os
import logging

from datetime import datetime, timedelta
from google.appengine.ext.webapp import template
from google.appengine.api import users
# from google.appengine.api import memcache
# from google.appengine.ext import db
from google.appengine.ext import webapp
from appengine_utilities.flash import Flash

from tabular import tabularize, untabularize
from builder.models import *

template_path = os.path.join(os.path.dirname(__file__), '..', '..', 'templates')
template.register_template_library('myfilters')

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
        self.read_flash()
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
    self.data = dict(now = self.now)
    
  def finish_request(self):
    raise FinishRequest
    
  def read_flash(self):
    try:
      self._flash = Flash()
    except EOFError:
      # this is a workaround for an unknown problem when running live on Google App Engine
      class PseudoFlash:
        def __init__(self):
          self.msg = ''
      self._flash = PseudoFlash()
    self.data.update(flash = self._flash.msg)
    
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
    self.data.update(config = self.config, server_name = self.config.server_name,
      server_host = self.request.host)
        
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
    
  def access_denied(self, message = None, attemp_login = True):
    if attemp_login and self.user == None and self.request.method == 'GET':
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
      builder.bind_environment(self.config, self.now)
    for builder in result:
      count = builder.messages.filter('state =', 0).order('created_at').count(limit = 10)
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
    
  def start_build(self, version, builder, repo_configuration):
    repo_configuration = tabularize(repo_configuration)
    
    build = Build(project = self.project, version = version, builder = builder, created_by = self.user,
      repo_configuration = repo_configuration, state = BUILD_QUEUED)
    build.put()

    body = "SET\tver\t%s\nPROJECT\t%s\t%s\n%s\n%s\n%s" % (version, self.project.permalink, self.project.name,
      self.config.common_script, repo_configuration, self.project.script)

    message = Message(builder = builder, build = build, body = body)
    message.put()
