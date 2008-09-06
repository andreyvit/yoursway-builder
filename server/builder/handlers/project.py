# -*- coding: utf-8 -*-

import logging

from datetime import datetime, timedelta
from google.appengine.api import memcache
from google.appengine.ext import db

from builder.models import *
from builder.handlers.base import prolog, BaseHandler

from builder.utils import create_token
from builder.data.chosen_repos import repo_configuration_info

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
    self.project.continuous_builder = Builder.all().filter('name =', self.request.get('project_continuous_builder')).get()
    
    if self.project.continuous_token == None:
      self.project.continuous_token = create_token()

    errors = self.project.validate()
    if len(errors) == 0:
      self.project.derive_info_from_script(self.config.common_script)
      self.project.put()
      self.redirect('/projects/%s' % self.project.urlname())
    else:       
      self.render_editor(errors)          

  def render_editor(self, errors = dict()):
    builders = self.fetch_active_builders()
    self.data.update(errors = errors, edit = self.project.is_saved(), builders = builders)
    self.render_and_finish('project', 'editor.html')
    
    # used_repositories = self._calculate_used_repositories(self.project.script)
  def _calculate_used_repositories(script):
    used_repositories = []
    for line in script.split("\n"):
      if len(line) == 0 or line[0:1] == '#':
        continue
      cmd, args = (line + "\t").split("\t", 1)
      if cmd == 'VERSION':
        xx, repos_name, rem = (args + "\t\t").split("\t", 2)
        if len(repos_name) > 0:
          used_repositories.append(repos_name)
    return list(Set(used_repositories))

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
    
    prefs = find_or_create(ProfileProjectPreferences, dict(profile = self.profile, project = self.project))
    
    if self.effective_level > VIEWER_LEVEL:
      builders = self.fetch_active_builders()
      online_builders = [b for b in builders if b.is_online()]
      recent_builders = [b for b in builders if not b.is_online()]
    
      last_used_builder = self.profile.last_used_builder
      if last_used_builder and last_used_builder.key() not in map(lambda b: b.key(), builders):
        last_used_builder = None
        
      repo_configuration = untabularize(repo_configuration_info(), prefs.repository_choices)
      script_info = self.project.script_info()
      for repos in script_info.alternable_repositories:
        if repo_configuration.has(repos.name):
          repos.chosen_one = repo_configuration.get(repos.name).location_name
        else:
          repos.chosen_one = 'default'
      
      self.data.update(online_builders = online_builders, recent_builders = recent_builders,
        builders = online_builders + recent_builders, last_used_builder = last_used_builder)
    
    num_latest = self.config.num_latest_builds
    num_recent = self.config.num_recent_builds
    builds = self.project.builds.order('-created_at').fetch(max(num_latest, num_recent))
    for build in builds:
      build.calculate_time_deltas(self.now)
    for build in builds:
      build.check_abandoning(self.config.build_abandoned_after)
    
    latest_builds = builds[0:num_latest]
    recent_builds = builds[0:num_recent]
    for build in latest_builds:
      build.calculate_derived_data()
      build.calculate_active_message()
      
    recent_builds = filter(lambda build: build.state != BUILD_SUCCEEDED, recent_builds)

    num_successful = num_recent
    successful_builds = self.project.builds.filter('state =', BUILD_SUCCEEDED).order('-created_at').fetch(num_successful)
    for build in successful_builds:
      build.calculate_time_deltas(self.now)

    next_version = calculate_next_version(builds[0] if builds else None)
    
    self.data.update(
      latest_builds = latest_builds,
      recent_builds = recent_builds,
      successful_builds = successful_builds,
      num_latest_builds = num_latest,
      num_recent_builds = num_recent,
      num_successful = num_successful,
      next_version = next_version,
    )
    self.render_and_finish('project', 'index.html')
