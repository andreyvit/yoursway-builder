
class varying_string(object):
  def __init__(self, many, one = None, zero = None):
    self.one = one
    self.many = many
    self.zero = zero
  
  def __mod__(self, n):
    t = self.choose_template(n)
    if t.find('%') >= 0:
      return t % n
    else:
      return t
    
  def choose_template(self, n):
    if self.zero and n == 0:
      return self.zero
    if self.one and n == 1:
      return self.one
    return self.many

class format_rule(object):
  def __init__(self, message, maximum = None, divisor = 1, minimum = 1, raw_maximum = None):
    if not hasattr(message, 'choose_template'):
      message = varying_string(many = message)
    self.message = message
    self.maximum = maximum
    self.minimum = minimum
    self.raw_maximum = raw_maximum
    self.divisor = divisor
    
  def __mod__(self, seconds):
    if self.raw_maximum and seconds > self.raw_maximum:
      return None
    value = (seconds + self.divisor / 2) / self.divisor
    if self.maximum and value >= self.maximum:
      return None
    if value < self.minimum:
      value = self.minimum
    return self.message % value
    
class choose_rule(object):
  def __init__(self, *rules):
    self.rules = rules
    
  def __mod__(self, seconds):
    for rule in self.rules:
      result = rule % seconds
      if not result == None:
        return result
    raise "No matching rule"

class compound_rule(object):
  def __init__(self, *rules):
    self.rules = rules

past_delta_rule = choose_rule(
  format_rule("a few seconds ago", maximum = 10),
  format_rule("less than a minute ago", maximum = 60),
  format_rule(varying_string("%d minutes ago", "one minute ago"), maximum = 55, divisor = 60),
  format_rule(varying_string("%d hours ago", "one hour ago"), maximum = 23, divisor = 60*60),
  format_rule(varying_string("%d days ago", "one day ago"), maximum = 13, divisor = 60*60*24),
  format_rule("%d weeks ago", minimum = 2, divisor = 60*60*24*7, raw_maximum = 60*60*24*26),
  format_rule(varying_string("%d months ago", "one month ago"), maximum = 11, divisor = 60*60*24*30),
  format_rule(varying_string("%d years ago", "one year ago"), maximum = None, divisor = 60*60*24*365),
)

future_delta_rule = choose_rule(
  format_rule("in a few seconds", maximum = 10),
  format_rule("in less than a minute", maximum = 60),
  format_rule(varying_string("in %d minutes", "in one minute"), maximum = 55, divisor = 60),
  format_rule(varying_string("in %d hours", "in one hour"), maximum = 23, divisor = 60*60),
  format_rule(varying_string("in %d days", "in one day"), maximum = 13, divisor = 60*60*24),
  format_rule("in %d weeks", minimum = 2, divisor = 60*60*24*7, raw_maximum = 60*60*24*26),
  format_rule(varying_string("in %d months", "in one month"), maximum = 11, divisor = 60*60*24*30),
  format_rule(varying_string("in %d years", "in one year"), maximum = None, divisor = 60*60*24*365),
)

def delta_to_seconds(seconds_or_delta):
  if hasattr(seconds_or_delta, 'days'):
    return seconds_or_delta.days * 24 * 60 * 60 + seconds_or_delta.seconds
  else:
    return seconds_or_delta

def time_delta_in_words(seconds_or_delta):
  seconds = delta_to_seconds(seconds_or_delta)
  if seconds == 0:
    return "now"
  elif seconds < 0:
    return past_delta_rule % -seconds
  else:
    return future_delta_rule % seconds

def test():
  from datetime import timedelta
  
  print "\nvarying_string -----------------------------"
  s = varying_string("%d minutes", "1 minute")
  print s % 1
  print s % 10
  print s % 0
  
  print "\npast_delta_rule ----------------------------"
  
  def test_rule(mul, delta):
    print "  %s --> %s" % (delta, time_delta_in_words(delta * mul))

  def test_rules(mul):
    test_rule(mul, timedelta(seconds = 5))
    test_rule(mul, timedelta(seconds = 20))
    test_rule(mul, timedelta(seconds = 65))
    test_rule(mul, timedelta(minutes = 4))
    test_rule(mul, timedelta(minutes = 59))
    test_rule(mul, timedelta(minutes = 65))
    test_rule(mul, timedelta(hours = 5))
    test_rule(mul, timedelta(hours = 23))
    test_rule(mul, timedelta(hours = 28))
    test_rule(mul, timedelta(days = 10))
    test_rule(mul, timedelta(days = 13))
    test_rule(mul, timedelta(days = 25))
    test_rule(mul, timedelta(days = 27))
    test_rule(mul, timedelta(days = 60))
    test_rule(mul, timedelta(days = 30*5+25))
    test_rule(mul, timedelta(days = 300))
    test_rule(mul, timedelta(days = 330))
    test_rule(mul, timedelta(days = 365*10))
    
  print "past rules:"
  test_rules(-1)
  print "future rules:"
  test_rules(1)

if __name__ == '__main__':
  test()
