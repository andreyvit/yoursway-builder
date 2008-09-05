
from copy import copy, deepcopy

from builder.utils import append

class repo_configuration_info(object):
  
  def __init__(self):
    self.parent = None
    self.choices_by_repo = {}
    self.choices = []
    
  def has(self, repos_name):
    return self.choices_by_repo.has_key(repos_name)
    
  def get(self, repos_name):
    return self.choices_by_repo[repos_name]
    
  def set(self, repos_name, reason, location_name):
    try:
      choice = self.choices_by_repo[repos_name]
      choice.reason = reason
      choice.location_name = location_name
    except KeyError:
      self.add_choice(repo_choice_info(repos_name, reason, location_name))
      
  def add_choice(self, choice):
    self.choices_by_repo[choice.repos_name] = append(self.choices, choice)
    
  def tabularize(self, array):
    for choice in self.choices:
      array.append(['CHOOSE', choice.repos_name, choice.reason, choice.location_name])
      
  def on_choose(self, repos_name, reason, location_name):
    self.add_choice(repo_choice_info(repos_name, reason, location_name))
    
  def without_default_choices(self):
    result = repo_configuration_info()
    for choice in self.choices:
      if not choice.is_default():
        result.add_choice(copy(choice))
    return result
    
class repo_choice_info(object):
  
  def __init__(self, repos_name, reason, location_name):
    self.repos_name = repos_name
    self.reason = reason
    self.location_name = location_name
    
  def is_default(self):
    return self.reason == 'default'
