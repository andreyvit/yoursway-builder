#!/usr/bin/env python
# -*- coding: utf-8 -*-

from google.appengine.ext import webapp
from google.appengine.ext.webapp.util import run_wsgi_app

from builder.handlers.index import IndexHandler, ProjectsHandler
from builder.handlers.people import PeopleHandler, CrudePersonHandler
from builder.handlers.project import CreateEditProjectHandler, ProjectHandler, DeleteProjectHandler
from builder.handlers.build import ProjectBuildHandler, BuildProjectHandler, StartContinuousBuildProjectHandler, AbortProjectBuildHandler
from builder.handlers.build import BuilderObtainWorkHandler, BuilderMessageDoneHandler, ReportProgressHandler, MessageConsoleHandler
from builder.handlers.server import SelfUpdateRequestHandler, ServerConfigHandler
    
url_mapping = [
  ('/', IndexHandler),
  ('/self-update-request', SelfUpdateRequestHandler),
  ('/people', PeopleHandler),
  ('/people/(invite)', CrudePersonHandler),
  ('/people/([^/]*)', CrudePersonHandler),
  ('/projects', ProjectsHandler),
  ('/projects/(new)', CreateEditProjectHandler),
  ('/projects/([^/]*)', ProjectHandler),
  ('/projects/([^/]*)/edit', CreateEditProjectHandler),
  ('/projects/([^/]*)/delete', DeleteProjectHandler),
  ('/projects/([^/]*)/build', BuildProjectHandler),
  ('/projects/([^/]*)/start_continuous_build', StartContinuousBuildProjectHandler),
  ('/projects/([^/]*)/builds/([^/]*)', ProjectBuildHandler),
  ('/projects/([^/]*)/builds/([^/]*)/abort', AbortProjectBuildHandler),
  
  ('/builders/([^/]*)/obtain-work', BuilderObtainWorkHandler),
  ('/builders/([^/]*)/messages/([^/]*)/done', BuilderMessageDoneHandler),
  ('/messages/([^/]*)/report_progress', ReportProgressHandler),
  ('/messages/([^/]*)/console', MessageConsoleHandler),
  ('/server-config', ServerConfigHandler),
]
application = webapp.WSGIApplication(url_mapping, debug=True)

def main():
  run_wsgi_app(application)

if __name__ == '__main__':
  main()
