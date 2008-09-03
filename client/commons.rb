
require 'generator'

class Symbol
  def to_proc
    proc { |obj, *args| obj.send(self, *args) }
  end
end

class Generator
  def next_or_nil
    if self.next? then self.next else nil end
  end
end

class Integer
  
  def choose_size_multiplier
    if self < 1024
      [1, "B"]
    elsif self < 1024*1024
      [1024, "KiB"]
    else
      [1204*1024, "MiB"]
    end
  end
  
  def format_size digits=0
    div, name = choose_size_multiplier
    digits = 0 if div == 1
    sprintf("%.#{digits}f #{name}", (self * 1.0 / div))
  end
  
  def format_size_of_size total_size, digits=0
    div1, name1 = self.choose_size_multiplier
    div2, name2 = total_size.choose_size_multiplier
    if div1 == div2
      "#{sprintf("%.#{digits}f", self*1.0/div1)} / #{sprintf("%.#{digits}f", total_size*1.0/div2)} #{name1}"
    else
      "#{self.format_size(digits)} / #{total_size.format_size(digits)}"
    end
  end
  
end

module YourSway
  
  class PathMapping
    
    attr_reader :first_prefix, :second_prefix
    
    def initialize first_prefix, second_prefix
      @first_prefix  = first_prefix .add_trailing_slash.drop_leading_slash
      @second_prefix = second_prefix.add_trailing_slash.drop_leading_slash
    end
    
    def first_to_second first_path
      raise "1st path #{first_path} does not match this mapping" unless first_path.matches_path_prefix? @first_prefix
      first_path.replace_prefix @first_prefix, @second_prefix
    end
    
    def second_to_first second_path
      raise "2nd path #{second_path} does not match this mapping" unless second_path.matches_path_prefix? @second_prefix
      second_path.replace_prefix @second_prefix, @first_prefix
    end
    
  end
  
  class SequenceDiffer
    
    def initialize
      @on_first = @on_second = @on_both = proc {}
    end
    
    def on_first &block; @on_first = block; end
    def on_second &block; @on_second = block; end
    def on_both &block; @on_both = block; end

    def run_diff! first, second
      first_gen = Generator.new(first.sort { |a, b| yield(a,b) })
      second_gen = Generator.new(second.sort { |a, b| yield(a,b) })
      first_cur = first_gen.next_or_nil
      second_cur = second_gen.next_or_nil
      until first_cur.nil? or second_cur.nil?
        case yield(first_cur, second_cur)
        when -1
          @on_first.call first_cur
          first_cur = first_gen.next_or_nil
        when 1
          @on_second.call second_cur
          second_cur = second_gen.next_or_nil
        when 0
          @on_both.call first_cur, second_cur
          first_cur = first_gen.next_or_nil
          second_cur = second_gen.next_or_nil
        end
      end
      until first_cur.nil?
        @on_first.call first_cur
        first_cur = first_gen.next_or_nil
      end
      until second_cur.nil?
        @on_second.call second_cur
        second_cur = second_gen.next_or_nil
      end
    end
    
  end
  
  module ArrayAdditions
    
    def process_and_remove_each
      until self.empty?
        yield self.first
        self.shift
      end
    end
    
    def compute_prefix_mapping
      self.collect { |obj| [yield(obj), obj] }.sort { |b,a| a[0].length <=> b[0].length }
    end
    
  end
  
  module StringAdditions
    
    def remove_leading_slash
      if self.starts_with? '/' then self[1..-1] else self end
    end
    
    def subst_empty default_value
      if self.empty? then default_value else self end
    end

    def starts_with? prefix
      prefix.length == 0 or self[0..prefix.length-1] == prefix
    end

    def ends_with? suffix
      self[-suffix.length..-1] == suffix
    end

    def drop_prefix prefix
      if self.starts_with? prefix then self[prefix.length..-1] else self end
    end

    def drop_prefix_or_fail prefix
      return self[prefix.length..-1] if self.starts_with? prefix
      raise "'#{self}' does not start with '#{prefix}'"
    end

    def drop_suffix prefix
      if self.ends_with? suffix then self[0..-suffix.length-1] else self end
    end

    def drop_suffix_or_fail suffix
      return self[0..-suffix.length-1] if self.ends_with? suffix
      raise "'#{self}' does not end with '#{suffix}'"
    end
    
    def add_suffix suffix
      if starts_with? suffix then self else "#{self}#{suffix}" end
    end
    
    def add_trailing_slash
      add_suffix '/'
    end
    
    def drop_leading_slash
      drop_prefix '/'
    end
    
    def matches_path_prefix? prefix
      self.add_trailing_slash.drop_leading_slash.starts_with?(prefix.add_trailing_slash.drop_leading_slash)
    end
    
    def replace_prefix old_prefix, new_prefix
      self[old_prefix.length..-1] + new_prefix
    end
    
  end
  
  class PathMappingMatcher

    def initialize mappings
      @first_to_mappings  = mappings.compute_prefix_mapping(&:first_prefix)
      @second_to_mappings = mappings.compute_prefix_mapping(&:second_prefix)
    end
    
    def lookup_first first_prefix
      r = @first_to_mappings.find { |fc, mapping| first_prefix.matches_path_prefix?(fc) }
      r && r[1]
    end
    
    def lookup_second second_prefix
      r = @second_to_mappings.find { |sc, mapping| second_prefix.matches_path_prefix?(sc) }
      r && r[1]
    end
    
  end
  
end

Array.send(:include, YourSway::ArrayAdditions)
String.send(:include, YourSway::StringAdditions)
