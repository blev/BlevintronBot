## This file is part of BrokenLinkBot
## (C) 2012 Blevintron
## This code is released under the CC-BY-SA 3.0 License.  See LICENSE.txt

## Description: multiplexing for an output object.
## Description: wrap lines at a particular column,
## Description: indent all lines, and write each
## Description: line atomically.

# Looks like class IO
class TMux
  def initialize(fout, indent=0, width=TMUX_COLUMN_WRAP)
    @fout = fout
    @fout.flush

    @indent = indent
    @width = width
    @line = ''
  end

  def puts(s='')
    print s
    print "\n"
  end

  def << s
    print s
  end

  def print s
    s ||= '(nil)'
    @line << (s.to_s)
    flush?
  end

  def flush
    flush?
    if @line != ''
      write_indent @line
      @line = ''
    end
  end

  def close
    flush
    @fout.close
    @fout = nil
  end

private
  def flush?
    until @line == ''
      # If the line is multi-line, flush the first line
      line0, nl, remnants = @line.partition "\n"
      if nl == "\n"
        flush_line line0
        @line = remnants
        next
      end

      if @line.size >= 2*@width
        @line = flush_prefix @line
        next
      end

      break
    end
  end

  def flush_line line
    while line.size >= @width
      line = flush_prefix line
    end

    unless line == ''
      line << "\n"
      write_indent line
    end
  end

  def flush_prefix line
    # Break at last white space
    col = line.rindex(/\s+/, @width)

    # Failing that...
    unless col
      # Break /after/ last forward slash
      col = line.rindex(/\//, @width)
      col += 1 if col
    end

    # Failing that... just break
    col ||= @width

    before = line[0 ... col] + "\n"
    write_indent before

    col2 = line.index(/\S/,col) || col
    return line[ col2 .. -1 ]
  end

  def write_indent str
    prefix = ' ' * @indent
    line = prefix + str

    until line == ''
      begin
        nr = @fout.syswrite line
        line = line[nr .. -1]
      rescue Errno::EINTR => e
        # Retry on interrupt.
      end
    end
  end

end


