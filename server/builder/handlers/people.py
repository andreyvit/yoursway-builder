# -*- coding: utf-8 -*-

import logging

from datetime import datetime, timedelta
from google.appengine.api import memcache
from google.appengine.ext import db

from builder.models import *
from builder.handlers.base import prolog, BaseHandler

class PeopleHandler(BaseHandler):
  @prolog(fetch = ['profiles'], required_level = ADMIN_LEVEL)
  def get(self):
    self.render_and_finish('people', 'index.html')

class CrudePersonHandler(BaseHandler):
  @prolog(path_components = ['profile'], required_level = ADMIN_LEVEL)
  def get(self, project_key):
    self.render_editor()

  @prolog(path_components = ['profile'], required_level = ADMIN_LEVEL)
  def post(self, project_key):
    if self.profile.is_saved and self.request.get('delete'):
      if self.request.get('confirm'):
        self.profile.delete()
        self.redirect_and_finish('/people',
          flash = "%s is deleted." % self.profile.email)
      else:
        self.redirect_and_finish(self.request.uri,
          flash = "Please confirm deletion by checking the box.")
      
    if not self.profile.is_saved():
      self.profile.invited_by = self.user
    self.profile.email = self.request.get('email')
    self.profile.level = int(self.request.get('level'))

    # errors = self.profile.validate()
    # if len(errors) == 0:
    self.profile.put()
    self.redirect_and_finish('/people',
      flash = ("%s saved." if self.profile.is_saved() else "%s added.") % self.profile.email)
    # else:
    #   self.render_editor(errors)

  def render_editor(self, errors = dict()):
    self.data.update(errors = errors, edit = self.profile.is_saved())
    self.render_and_finish('people', 'invite.html')
