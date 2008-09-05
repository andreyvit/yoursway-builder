
from random import choice
      
def append(list, item):
  list.append(item)
  return item

def create_token(len = 10):
  result = ''
  for i in xrange(len):
    result += choice('abcdefghijklmnoprstuvwxyz0123456789')
  return result
