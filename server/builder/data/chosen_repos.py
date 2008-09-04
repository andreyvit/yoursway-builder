
from builder.utils import append

class repo_configuration_info(object):
  
  def __init__(self):
    self.parent = None
    self.choices_by_repo = {}
    self.choices = []
    
  def set(self, repos_name, reason, location_name):
    try:
      choice = self.choices_by_repo[repos_name]
      choice.reason = reason
      choice.location_name = location_name
    except KeyError:
      self.choices_by_repo[repos_name] = append(self.choices, repo_choice_info(repos_name, reason, location_name))
    
  def tabularize(self, array):
    for choice in self.choices:
      array.append(['CHOOSE', choice.repos_name, choice.reason, choice.location_name])
      
  def on_choose(self, repos_name, reason, location_name):
    self.choices_by_repo[repos_name] = append(self.choices, repo_choice_info(repos_name, reason, location_name))
    
class repo_choice_info(object):
  
  def __init__(self, repos_name, reason, location_name):
    self.repos_name = repos_name
    self.reason = reason
    self.location_name = location_name
