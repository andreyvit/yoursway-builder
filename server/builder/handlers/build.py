# -*- coding: utf-8 -*-

import logging

from datetime import datetime, timedelta
from google.appengine.api import memcache
from google.appengine.ext import db

from builder.models import *
from builder.handlers.base import prolog, BaseHandler

from builder.data.perproject import script_info
from builder.data.chosen_repos import repo_configuration_info

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

    script_info = self.project.script_info()
    repo_configuration = repo_configuration_info()
    for repos in script_info.alternable_repositories:
      chosen_location_name = (self.request.get("location_%s" % repos.permalink) or '')
      if chosen_location_name == '':
        self.redirect_and_finish('/projects/%s' % self.project.urlname(),
          flash = "Sorry, please also choose a repository for %s." % (repos.name))
      default_location = repos.locations[0]
      if chosen_location_name == default_location.name:
        repo_configuration.set(repos.name, 'default', default_location.name)
      elif chosen_location_name in map(lambda l: l.name, repos.locations):
        repo_configuration.set(repos.name, 'manual', chosen_location_name)
      else:
        raise str("Sorry, location %s is no longer available for repository %s." % (chosen_location_name, repos.name))
        self.redirect_and_finish('/projects/%s' % self.project.urlname(),
          flash = "Sorry, location %s is no longer available for repository %s." % (chosen_location_name, repos.name))

    self.start_build(version, self.builder, repo_configuration)
    
    if self.profile:
      self.profile.last_used_builder = self.builder
      self.profile.put()
    
    self.redirect_and_finish('/projects/%s' % self.project.urlname(),
      flash = "Started bulding version %s. Please refresh this page to track status." % version)

class StartContinuousBuildProjectHandler(BaseHandler):
  @prolog(path_components = ['project'])
  def post(self, project_key):
    token = self.request.get('token')
    logging.info('token is %s' % token)
    if token != self.project.continuous_token:
      self.access_denied("Invalid token", attemp_login = False)
      
    builder = self.project.continuous_builder
    logging.info('token ok; builder is %s' % builder)
    if builder == None:
      self.not_found("Continuous builds are disabled for this project")

    latest_build = self.project.builds.order('-created_at').get()
    version = calculate_next_version(latest_build)
    logging.info('builder ok; version is %s' % version)

    existing_count = self.project.builds.filter('version =', version).count()
    if existing_count > 0:
      logging.info("Ignoring build request with the same version number (%s, project %s)" % (version, self.project.name))
      self.error(400)
      return
      
    script_info = self.project.script_info()
    repo_configuration = repo_configuration_info()
    for repos in script_info.alternable_repositories:
      repo_configuration.set(repos.name, 'default', repos.locations[0].name)

    self.start_build(version, builder, repo_configuration)

    self.response.out.write("OK\t%s" % version)
    
  get = post

class BuilderObtainWorkHandler(BaseHandler):
  def get(self):
    self.post()
    
  @prolog(path_components = ['builder'])
  def post(self, name):
    message = None
    if self.builder.is_saved():
      # handle stale messages
      stale_messages = self.builder.messages.filter('state =', MESSAGE_INPROGRESS).filter('created_at <', (self.now - timedelta(seconds = 60*60))).order('created_at').fetch(100)
      for message in stale_messages:
        message.abandon_and_put()
        
      # handle stale builds
      stale_builds = Build.all().filter('builder =', self.builder).filter('state =', BUILD_INPROGRESS).fetch(1000)
      logging.info("found %d stale build(s)" % len(stale_builds))
      for build in stale_builds:
        build.abandon_and_put()
        
      # check for selfupdate request
      if self.builder.self_update_requested:
        self.builder.self_update_requested = False
        self.builder.put()
        self.response.out.write("SELFUPDATE\tv1")
        self.finish_request()
    
      # retrieve the next message to process
      message = self.builder.messages.filter('state =', 0).order('created_at').get()
      
    if message == None:
      self.response.out.write("IDLE\tv1\t%d" % self.config.builder_poll_interval)
      self.builder.busy = False
    else:
      message.state = MESSAGE_INPROGRESS
      message.put()
      build = message.build
      build.state = BUILD_INPROGRESS
      build.put()
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

    message.state = MESSAGE_DONE
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

    key = "progress-%s" % (message_key)
    memcache.set(key, "FIN", time = 60*60)

class ReportProgressHandler(BaseHandler):
  def post(self, message_key):
    console = self.request.get('console')
    key = "progress-%s" % (message_key)
    memcache.set(key, console, time = 60*60)
    
    # bs = memcache.get("message-builderstate-%s" % message_key)
    # if bs is None:
    #   
    # self.builder.last_check_at = datetime.now()
    # self.builder.put()
  
    
  get = post

class MessageConsoleHandler(BaseHandler):
  def post(self, message_key):
    key = "progress-%s" % (message_key)
    value = memcache.get(key)
    if value is None:
      self.response.out.write("Waiting for log from the builder...")
    elif value == "FIN":
      self.response.out.write("<script>reload_page()</script>Reloading page...")
    else:
      self.response.out.write("%s" % value)
      
  get = post
