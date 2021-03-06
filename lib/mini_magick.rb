require "open-uri"
require "stringio"
require "fileutils"
require "open3"

require File.join(File.dirname(__FILE__), '/image_temp_file')

module MiniMagick
  class MiniMagickError < RuntimeError; end

  class Image
    attr :path
    attr :tempfile
    attr :output

    # Class Methods
    # -------------
    class << self
      def from_blob(blob, ext = nil, &block)
        begin
          tempfile = ImageTempFile.new(ext)
          tempfile.binmode
          tempfile.write(blob)
        ensure
          tempfile.close if tempfile
        end

        return self.new(tempfile.path, tempfile, &block)
      end

      # Use this if you don't want to overwrite the image file
      def open(image_path, &block)
        File.open(image_path, "rb") do |f|
          self.from_blob(f.read, File.extname(image_path), &block)
        end
      end
      alias_method :from_file, :open
      
      def blank(size = "1x1", colour = "none", ext = "png")
        from_blob("", ext) do |image|
          image.blank size, colour
        end
      end
    end

    # Instance Methods
    # ----------------
    def initialize(input_path, tempfile=nil, &block)
      @path = input_path
      @tempfile = tempfile # ensures that the tempfile will stick around until this image is garbage collected.

      yield(self) if block_given?
      
      # Ensure that the file is an image
      run_command("identify", @path)
    end

    # For reference see http://www.imagemagick.org/script/command-line-options.php#format
    def [](value)
      # Why do I go to the trouble of putting in newlines? Because otherwise animated gifs screw everything up
      case value.to_s
      when "format"
        run_command("identify", "-format", format_option("%m"), @path).split("\n")[0]
      when "height"
        run_command("identify", "-format", format_option("%h"), @path).split("\n")[0].to_i
      when "width"
        run_command("identify", "-format", format_option("%w"), @path).split("\n")[0].to_i
      when "dimensions"
        run_command("identify", "-format", format_option("%w %h"), @path).split("\n")[0].split.map{|v|v.to_i}
      when "size"
        File.size(@path) # Do this because calling identify -format "%b" on an animated gif fails!
      when "original_at"
        # Get the EXIF original capture as a Time object
        Time.local(*self["EXIF:DateTimeOriginal"].split(/:|\s+/)) rescue nil
      when /^EXIF\:/i
        run_command('identify', '-format', "\"%[#{value}]\"", @path).chop
      else
        run_command('identify', '-format', "\"#{value}\"", @path).split("\n")[0]
      end
    end

    # Sends raw commands to imagemagick's mogrify command. The image path is automatically appended to the command
    def <<(*args)
      run_command("mogrify", *args << @path)
    end

    # This is a 'special' command because it needs to change @path to reflect the new extension
    # Formatting an animation into a non-animated type will result in ImageMagick creating multiple
    # pages (starting with 0).  You can choose which page you want to manipulate.  We default to the
    # first page.
    def format(format, page=0)
      old_path = @path.dup
      @path = "#{@path}.#{format}"
      run_command("convert", "-format", format, old_path, @path)
      File.delete(old_path)
    
      # convert the paged file if necessary
      unless File.exists?(@path)
        paged_path = "#{old_path}-#{page}.#{format}"
        FileUtils.copy_file(paged_path, @path) if File.exists?(paged_path)
      end
      raise MiniMagickError, "Unable to format to #{format}" unless File.exists?(@path)

      # move to new tempfile
      if @tempfile
        @tempfile.close!
        @tempfile = ImageTempFile.new(format)
        FileUtils.mv @path, @tempfile.path
        @path = @tempfile.path
      end
      
      self
    ensure
      Dir["#{old_path}-[0-9]*.#{format}"].each {|fname| File.unlink(fname) } # cleanup paged paths
    end

    # return a composite image with the passed image laid over
    # 1st argument is another Image, further options are passed to the composite command
    def composite(image, opts = {})
      image_path = image.is_a?(Image) ? image.path : image
      args = hash_to_args(opts) + [image_path, @path, @path]
      run_command('composite', *args)
      self
    end
    
    # colour the image with the passed image as a colour lookup table
    def clut(image, opts = {})
      image_path = image.is_a?(Image) ? image.path : image
      args = ['-clut'] + hash_to_args(opts) + [@path, image_path, @path]
      run_command('convert', *args)
      self
    end
    
    # overwrite the image with a blank canvas
    def blank(size, colour, opts = {})
      args = ['-size', size, "xc:#{colour}"] + hash_to_args(opts) + [@path]
      run_command('convert', *args)
      self
    end
    
    # Writes the temporary image that we are using for processing to the output path
    def write(output_path)
      FileUtils.copy_file @path, output_path
      run_command "identify", output_path # Verify that we have a good image
    end

    # Give you raw data back
    def to_blob
      f = File.new @path
      f.binmode
      f.read
    ensure
      f.close if f
    end

    # If an unknown method is called then it is sent through the morgrify program
    # Look here to find all the commands (http://www.imagemagick.org/script/mogrify.php)
    def method_missing(symbol, *args)
      args.push(@path) # push the path onto the end
      run_command("mogrify", "-#{symbol}", *args)
      self
    end

    # You can use multiple commands together using this method
    def combine_options(&block)
      c = CommandBuilder.new
      block.call c
      run_command("mogrify", *c.args << @path)
    end

    # Check to see if we are running on win32 -- we need to escape things differently
    def windows?
      !(RUBY_PLATFORM =~ /win32/).nil?
    end

    # Outputs a carriage-return delimited format string for Unix and Windows
    def format_option(format)
      windows? ? "#{format}\\n" : "#{format}\\\\n"
    end
  
    def run_command(command, *args)
      args.collect! do |arg|        
        # args can contain characters like '>' so we must escape them, but don't quote switches
        if arg !~ /^[\+\-]/
          "\"#{arg}\""
        else
          arg.to_s
        end
      end
    
      command = "#{command} #{args.join(' ')}"
      output = `#{command} 2>&1`
    
      if $?.exitstatus != 0
        raise MiniMagickError, "ImageMagick command (#{command.inspect}) failed: #{{:status_code => $?, :output => output}.inspect}"
      else
        output
      end
    end
    
    def hash_to_args(opts)
      opts.map {|k,v| "-#{k.to_s} #{v.to_s}"}
    end
  end

  class CommandBuilder
    attr :args

    def initialize
      @args = []
    end

    def method_missing(symbol, *args)
      @args << "-#{symbol}"
      @args += args
    end

    def +(value)
      @args << "+#{value}"
    end
  end
end
