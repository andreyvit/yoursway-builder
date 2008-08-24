
import os
from google.appengine.ext.webapp import template
from yslib.dates import time_delta_in_words

template_path = os.path.join(os.path.dirname(__file__), 'templates')

# template filters
register = template.create_template_register()

@register.filter
def timedelta(delta):
  return time_delta_in_words(delta)
@register.filter
def revtimedelta(delta):
  return time_delta_in_words(-delta)
  
# register.filter(time_delta_in_words)
