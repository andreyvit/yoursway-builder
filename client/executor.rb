
class Executor
  
  def initialize
    @variables = {}
  end
  
  def subst value
    return value.gsub(/\[([^\]]+)\]/) { |var|
      @variables[$1] or raise ExecutionError.new("Undefined variable [#{$1}]")
    }
  end
  
  def execute command, args, data_lines
    args.collect! { |arg| subst(arg) }
    data_lines.each { |line|
      line.collect! { |arg| subst(arg) }
    }
    
    case command.upcase
    when 'SAY'
      do_say *args
    when 'SET'
      do_set *args
    when 'INVOKE'
      do_invoke *args
    else
      log "Unknown command #{command}(#{args.join(', ')})"
    end
  end
  
  def do_say text
    log "Saying #{text}"
    invoke('say', text)
  end
  
  def do_set name, value
    @variables[name] = value
  end
  
  def do_invoke app, *args
    args = [''] if args.empty? # or else shell will be invoked
    log "Invoking #{app} with arguments #{args.join(', ')}"
    system(app, *args)
  end
  
end
