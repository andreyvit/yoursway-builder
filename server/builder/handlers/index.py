# -*- coding: utf-8 -*-

import logging

from datetime import datetime, timedelta
from google.appengine.api import memcache
from google.appengine.ext import db

from builder.models import *
from builder.handlers.base import prolog, BaseHandler
    
class ProjectsHandler(BaseHandler):
  @prolog(fetch = ['projects'])
  def get(self):
    self.render_and_finish('projects', 'list.html')

class IndexHandler(BaseHandler):
  def get(self):
    self.redirect('projects')
