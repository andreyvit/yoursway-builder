# -*- coding: utf-8 -*-

import logging

from datetime import datetime, timedelta
from google.appengine.api import memcache
from google.appengine.ext import db

from builder.models import *
from builder.handlers.base import prolog, BaseHandler

class SelfUpdateRequestHandler(BaseHandler):
  
  @prolog(required_level = ADMIN_LEVEL)
  def post(self):
    if self.request.get('confirm') != '1':
      self.redirect_and_finish('/projects', flash = "Please confirm self-update by checking the box.")
      
    builders = Builder.all().order('-last_check_at').fetch(100)
    for builder in builders:
      builder.self_update_requested = True
      builder.put()
      
    self.redirect_and_finish('/projects',
      flash = "Requested self-update of the following builders: %s." % ', '.join(map(lambda b: b.name, builders)))

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
    self.config.build_abandoned_after = int(self.request.get('build_abandoned_after'))
    self.config.common_script = self.request.get('common_script')
    if len(self.config.server_name) == 0:
      self.show_editor()
      
    self.config.put()
    self.redirect('/')

  def show_editor(self):      
    self.render_and_finish('server-config', 'editor.html')
