
from builder.utils import append
    
class script_info(object):
  def __init__(self):
    self.alternable_repositories = []
    self.all_repositories = []
    
  def tabularize(self, array):
    for repos in self.alternable_repositories:
      array.append(['AREPOSINFO', repos.name, repos.permalink, repos.descr])
      for location in repos.locations:
        array.append(['','LOCATION',location.name])

  def on_areposinfo(self, name, permalink, descr):
    return append(self.alternable_repositories, repos_info(name, descr, permalink = permalink))
    
  def on_areposinfo_location(self, repos, name):
    repos.add(repos_location_info(name))
  
  # parsing of real scripts
  
  def on_repos(self, name, tags, descr):
    return append(self.all_repositories, repos_info(name = name, descr = descr))

  def on_repos_git(self, repos, name, tags, url):
    repos.add(repos_location_info(name = name))
    
  def postprocess(self):
    self.alternable_repositories = filter(lambda r: len(r.locations) > 1, self.all_repositories)
    
class repos_info(object):
  def __init__(self, name, descr, permalink = None):
    self.name = name
    if permalink is None:
      permalink = name.replace('-', '_')
    self.permalink = permalink
    if descr == '' or descr == '-':
      descr = name
    self.descr = descr
    self.locations = []
    
  def add(self, location):
    self.locations.append(location)

class repos_location_info(object):
  def __init__(self, name):
    self.name = name
