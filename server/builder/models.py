# -*- coding: utf-8 -*-
from google.appengine.ext import db

from yslib.dates import time_delta_in_words, delta_to_seconds
from tabular import tabularize, untabularize
from builder.data.perproject import script_info
  
def calculate_next_version(latest_build):
  if latest_build is None:
    return '0.0.1'
  else:
    v = latest_build.version.split('.')
    v[-1] = str(int(v[-1]) + 1)
    return ".".join(v)

class InstallationConfig(db.Model):
  server_name = db.TextProperty(default = 'YourSway Builder')
  builder_poll_interval = db.IntegerProperty(default = 60)
  builder_offline_after = db.IntegerProperty(default = 120)
  builder_is_recent_within = db.IntegerProperty(default = 60*60*24)
  build_abandoned_after = db.IntegerProperty(default = 60*60)
  num_latest_builds = db.IntegerProperty(default = 3)
  num_recent_builds = db.IntegerProperty(default = 30)
  common_script = db.TextProperty(default = '')

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

class Builder(db.Model):
  name = db.StringProperty()
  created_at = db.DateTimeProperty(auto_now_add = True)
  last_check_at = db.DateTimeProperty()
  busy = db.BooleanProperty()
  progress = db.TextProperty()
  self_update_requested = db.BooleanProperty(default = False)

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

class Project(db.Model):
  name = db.StringProperty(default = '')
  permalink = db.StringProperty(default = '')
  owner = db.UserProperty()
  created_at = db.DateTimeProperty(auto_now_add=True)
  is_public = db.BooleanProperty(default = False)
  script = db.TextProperty(default = '')
  script_info_tab = db.TextProperty(default = '')
  continuous_builder = db.ReferenceProperty(Builder, collection_name = 'continuously_built_projects')
  continuous_token = db.StringProperty()
  
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
    
  def script_info(self):
    if not hasattr(self, '_script_info'):
      self._script_info = untabularize(script_info(),self.script_info_tab)
    return self._script_info
    
  def derive_info_from_script(self, common_script):
    self._script_info = untabularize(script_info(), common_script + "\n" + self.script)
    self._script_info.postprocess()
    self.script_info_tab = db.Text(tabularize(self._script_info))
    
def split_tags(s):
  if s == '-':
    return []
  else:
    return s.split(',')
    
BUILD_ABANDONED = 0
BUILD_SUCCEEDED = 1
BUILD_FAILED = 2
BUILD_INPROGRESS = 3
BUILD_QUEUED = 4
    
state_info = {
  BUILD_ABANDONED:  dict(name = 'abandoned',  color = 'grey'),
  BUILD_INPROGRESS: dict(name = 'inprogress', color = 'blue'),
  BUILD_QUEUED:     dict(name = 'queued',     color = 'blue'),
  BUILD_FAILED:     dict(name = 'failed',     color = 'red'),
  BUILD_SUCCEEDED:    dict(name = 'succeeded',  color = 'green'),
}

class Build(db.Model):
  project = db.ReferenceProperty(Project, collection_name = 'builds')
  builder = db.ReferenceProperty(Builder, collection_name = 'builds')
  state = db.IntegerProperty(default = BUILD_ABANDONED, choices = [BUILD_INPROGRESS, BUILD_QUEUED, BUILD_SUCCEEDED, BUILD_FAILED, BUILD_ABANDONED])
  repo_configuration = db.TextProperty(default = '')
  version = db.StringProperty()
  report = db.TextProperty(default = '')
  failure_reason = db.TextProperty(default = '')
  created_at = db.DateTimeProperty(auto_now_add = True)
  created_by = db.UserProperty()
      
  def set_active_message(self, message):
    self._active_message = message
    
  def active_message(self):
    return self._active_message

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
    
  def check_abandoning(self, build_abandoned_after):
    if self.state == BUILD_INPROGRESS and self._since_start > timedelta(seconds = build_abandoned_after):
      self.abandon_and_put()
        
  def abandon_and_put(self):
    logging.info("Build(%s).abandon_and_put()" % self.version)
    self.state = BUILD_ABANDONED
    self.put()
    
    messages = self.messages.filter('state =', MESSAGE_INPROGRESS).fetch(100)
    for message in messages:
      message.abandon_and_put()
    
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
    
  def is_queued_or_in_progress(self):
    return self.state in [BUILD_QUEUED, BUILD_INPROGRESS]
    
MESSAGE_QUEUED = 0
MESSAGE_INPROGRESS = 1
MESSAGE_DONE = 2
MESSAGE_ABANDONED = 3
    
class Message(db.Model):
  builder = db.ReferenceProperty(Builder, collection_name = 'messages')
  build = db.ReferenceProperty(Build, collection_name = 'messages')
  created_at = db.DateTimeProperty(auto_now_add = True)
  body = db.TextProperty()
  state = db.IntegerProperty(default = 0)
  
  def abandon_and_put(self):
    logging.info("Message(%s).abandon_and_put()" % self.key())
    self.state = MESSAGE_ABANDONED
    self.put()
    
    key = "progress-%s" % (self.key())
    memcache.set(key, "FIN", time = 60*60)

class Profile(db.Model):
  user = db.UserProperty()
  email = db.EmailProperty()
  level = db.IntegerProperty(default = NORMAL_LEVEL, choices = [ANONYMOUS_LEVEL, VIEWER_LEVEL, NORMAL_LEVEL, ADMIN_LEVEL, GOD_LEVEL])
  last_used_builder = db.ReferenceProperty(Builder, collection_name = 'last_used_by')

  def level_name(self):
    return level_names[self.level]

  def urlname(self):
    return self.email
