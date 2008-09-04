
def tabularize(receiver):
  array = []
  receiver.tabularize(array)
  return "\n".join(map(lambda row: "\t".join(row), array))
    
def untabularize(receiver, script, *root_context_args):
  prev_command = None
  context_args = ()
  for line in script.split("\n"):
    stripped = line.strip()
    if len(stripped) == 0 or stripped.startswith('#'):
      continue
    fields = line.split("\t")
    if len(fields[0]) == 0:
      command, args = fields[1].lower(), fields[2:]
      handler_name = "on_%s_%s" % (prev_command, command)
      
      if hasattr(receiver, handler_name):
        getattr(receiver, handler_name)(*(context_args + tuple(args)))
      
    else:
      if prev_command:
        handler_name = "after_%s" % prev_command
        if hasattr(receiver, handler_name):
          getattr(receiver, handler_name)(*context_args)
      
      command, args = fields[0].lower(), fields[1:]
      handler_name = "on_%s" % command
      prev_command = command
      
      if not hasattr(receiver, handler_name):
        continue
      context_args = (getattr(receiver, handler_name)(*(root_context_args + tuple(args))) or [])
      if context_args and not (type(context_args) is tuple):
        if type(context_args) is list:
          context_args = tuple(context_args)
        else:
          context_args = (context_args,)
    
  if prev_command:
    handler_name = "after_%s" % prev_command
    if hasattr(receiver, handler_name):
      getattr(receiver, handler_name)(*context_args)
      
  return receiver
