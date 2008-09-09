# -*- coding: utf-8 -*-

import logging

from datetime import datetime, timedelta
from google.appengine.api import memcache
from google.appengine.ext import db

from builder.models import *
from builder.handlers.base import prolog, BaseHandler

from tabular import tabularize, untabularize
from builder.data.perproject import script_info
from builder.data.chosen_repos import repo_configuration_info

class ProjectBuildHandler(BaseHandler):
  @prolog(path_components = ['project', 'build'], required_level = VIEWER_LEVEL)
  def get(self, project_key, build_key):
    self.build.calculate_time_deltas(self.now)
    self.build.calculate_derived_data()
    self.build.calculate_active_message()
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
    
    self.profile.last_used_builder = self.builder
    self.profile.put()
        
    update_or_insert(ProfileProjectPreferences, dict(profile = self.profile, project = self.project),
      repository_choices = tabularize(repo_configuration.without_default_choices()),
      initial_values = dict(project = self.project.key(), profile = self.profile.key()))
    
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
  
@transaction
def set_build_to_aborted(build_key):
  build = Build.get(build_key)
  if build.state in [BUILD_FAILED, BUILD_SUCCEEDED, BUILD_ABANDONED, BUILD_ABORTED]:
    return False
  build.state = BUILD_ABORTED
  build.put()
  return True
  
@transaction
def set_message_to_aborted(message_key):
  message = Message.get(message_key)
  if message.state in [MESSAGE_DONE, MESSAGE_ABANDONED, MESSAGE_ABORTED]:
    return False
  message.state = MESSAGE_ABORTED
  message.put()
  return True

class AbortProjectBuildHandler(BaseHandler):
  @prolog(path_components = ['project', 'build'], required_level = NORMAL_LEVEL)
  def post(self, project_key, build_key):
    anything_done = set_build_to_aborted(self.build.key())
    
    messages = self.build.messages.filter('state =', MESSAGE_INPROGRESS).fetch(100)
    messages += self.build.messages.filter('state =', MESSAGE_QUEUED).fetch(100)
    for message in messages:
      anything_done = set_message_to_aborted(message.key()) or anything_done
      memcache.delete("progress-%s" % message.key())
      self.invalidate_message_control(message.key())
    
    if anything_done:
      self.redirect_and_finish('/projects/%s' % self.project.urlname(),
        flash = "Aborted bulding of version %s." % self.build.version)
    else:
      self.redirect_and_finish('/projects/%s' % self.project.urlname(),
        flash = "Nothing to abort: building of version %s has already been finished." % self.build.version)
    
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
    
@transaction
def update_build_state_as_reported_by_builder(build_key, new_state, report, failure_reason = None):
  build = Build.get(build_key)
  build.state = new_state
  build.failure_reason = failure_reason
  build.report = report
  build.put()

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
    
    outcome = self.request.get("outcome")
    if outcome == 'ERR':
      update_build_state_as_reported_by_builder(build.key(), BUILD_FAILED, report = report, failure_reason = self.request.get("failure_reason"))
    elif outcome == 'SUCCESS':
      update_build_state_as_reported_by_builder(build.key(), BUILD_SUCCEEDED, report = report)
    elif outcome == 'ABORTED':
      update_build_state_as_reported_by_builder(build.key(), BUILD_ABORTED, report = report)
    else:
      update_build_state_as_reported_by_builder(build.key(), BUILD_FAILED, report = report, failure_reason = "Illegal outcome %s" % outcome)

    self.update_message_console(message_key, "FIN")

class ReportProgressHandler(BaseHandler):
  def post(self, message_key):
    console = self.request.get('console')
    self.update_message_console(message_key, console)
    
    control = self.get_message_control(message_key)
    self.response.out.write(control)
    
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
