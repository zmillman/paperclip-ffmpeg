module Paperclip
  class Ffmpeg < Processor
    attr_accessor :geometry, :format, :whiny, :convert_options

    # Creates a Video object set to work on the +file+ given. It
    # will attempt to transcode the video into one defined by +target_geometry+
    # which is a "WxH"-style string. +format+ should be specified.
    # Video transcoding will raise no errors unless
    # +whiny+ is true (which it is, by default. If +convert_options+ is
    # set, the options will be appended to the convert command upon video transcoding.
    def initialize file, options = {}, attachment = nil
      @convert_options = {
        :input => {},
        :output => { :y => nil }
      }
      unless options[:convert_options].nil? || options[:convert_options].class != Hash
        unless options[:convert_options][:input].nil? || options[:convert_options][:input].class != Hash
          @convert_options[:input].reverse_merge! options[:convert_options][:input]
        end
        unless options[:convert_options][:output].nil? || options[:convert_options][:output].class != Hash
          @convert_options[:output].reverse_merge! options[:convert_options][:output]
        end
      end
      
      @geometry        = options[:geometry]
      @file            = file
      @keep_aspect     = !@geometry.nil? && @geometry[-1,1] != '!'
      @pad_only        = @keep_aspect    && @geometry[-1,1] == '#'
      @enlarge_only    = @keep_aspect    && @geometry[-1,1] == '<'
      @shrink_only     = @keep_aspect    && @geometry[-1,1] == '>'
      @whiny           = options[:whiny].nil? ? true : options[:whiny]
      @format          = options[:format]
      @time            = options[:time].nil? ? 3 : options[:time]
      @current_format  = File.extname(@file.path)
      @basename        = File.basename(@file.path, @current_format)
      @meta            = identify
      @pad_color       = options[:pad_color].nil? ? "black" : options[:pad_color]
      @normalize_audio = options[:normalize_audio]
      attachment.instance_write(:meta, @meta)
    end
    
    # Performs the transcoding of the +file+ into a thumbnail/video. Returns the Tempfile
    # that contains the new image/video.
    def make
      src = @file
      dst = Tempfile.new([@basename, @format ? ".#{@format}" : ''])
      dst.binmode
      
      parameters = []
      # Add geometry
      if @geometry
        # Extract target dimensions
        if @geometry =~ /(\d*)x(\d*)/
          target_width = $1
          target_height = $2
        end
        # Only calculate target dimensions if we have current dimensions
        unless @meta[:size].nil?
          current_geometry = @meta[:size].split('x')
          # Current width and height
          current_width = current_geometry[0]
          current_height = current_geometry[1]
          if @keep_aspect
            if @enlarge_only
              if current_width.to_i < target_width.to_i
                # Keep aspect ratio
                width = target_width.to_i
                height = (width.to_f / (@meta[:aspect].to_f)).to_i
                @convert_options[:output][:s] = "#{width.to_i/2*2}x#{height.to_i/2*2}"
              else
                return nil
              end
            elsif @shrink_only
              if current_width.to_i > target_width.to_i
                # Keep aspect ratio
                width = target_width.to_i
                height = (width.to_f / (@meta[:aspect].to_f)).to_i
                @convert_options[:output][:s] = "#{width.to_i/2*2}x#{height.to_i/2*2}"
              else
                return nil
              end
            elsif @pad_only
              # Keep aspect ratio
              width = target_width.to_i
              height = (width.to_f / (@meta[:aspect].to_f)).to_i
              # We should add half the delta as a padding offset Y
              pad_y = (target_height.to_f - height.to_f) / 2
              if pad_y > 0
                @convert_options[:output][:vf] = "scale=#{width}:-1,pad=#{width.to_i}:#{target_height.to_i}:0:#{pad_y}:#@pad_color"
              else
                @convert_options[:output][:vf] = "scale=#{width}:-1,crop=#{width.to_i}:#{height.to_i}"
              end
            else
              # Keep aspect ratio
              width = target_width.to_i
              height = (width.to_f / (@meta[:aspect].to_f)).to_i
              @convert_options[:output][:s] = "#{width.to_i/2*2}x#{height.to_i/2*2}"
            end
          else
            # Do not keep aspect ratio
            @convert_options[:output][:s] = "#{target_width.to_i/2*2}x#{target_height.to_i/2*2}"
          end
        end
      end
      # Add format
      case @format
      when 'jpg', 'jpeg', 'png', 'gif' # Images
        @convert_options[:input][:ss] = @time
        @convert_options[:output][:vframes] = 1
        @convert_options[:output][:f] = 'image2'
      end
      
      # Add source
      parameters << @convert_options[:input].map { |k,v| "-#{k.to_s} #{v} "}
      parameters << "-i :source"
      if @normalize_audio
        # adds an additional input stream, taking video from the first, and audio from the second
        parameters << "-i :audio -map 0:v -map 1:a"
      end
      parameters << @convert_options[:output].map { |k,v| "-#{k.to_s} #{v} "}
      parameters << ":dest"

      parameters = parameters.flatten.compact.join(" ").strip.squeeze(" ")
      
      Paperclip.log("[ffmpeg] #{parameters}")
      begin
        if @normalize_audio
          log_file = '/dev/null' # we send stderr output to /dev/null -- TODO: better logging location
          # Copy the audio track from the video to a temporary wav file
          tmp_wav_file = Tempfile.new([@basename, ".wav"])
          tmp_wav_file.binmode
          Paperclip.run("ffmpeg", "-y -i :source -acodec pcm_s16le :audio 2>> :logfile", :source => File.expand_path(src.path), :audio => File.expand_path(tmp_wav_file.path), :logfile => log_file)
          # Run normalization on the wav file
          Paperclip.run('normalize-audio', ":audio 2>> :logfile", :audio => File.expand_path(tmp_wav_file.path), :logfile => log_file)
          # Encode final file with normalized audio track
          parameters += ' 2>> :logfile'
          Paperclip.run("ffmpeg", parameters, :source => File.expand_path(src.path), :dest => File.expand_path(dst.path), :audio => File.expand_path(tmp_wav_file.path), :logfile => log_file)
          tmp_wav_file.close
          tmp_wav_file.unlink
        else
          Paperclip.run("ffmpeg", parameters, :source => File.expand_path(src.path), :dest => File.expand_path(dst.path))
        end
      rescue Cocaine::ExitStatusError => e
        raise Paperclip::Error, "error while processing video for #{@basename}: #{e}" if @whiny
      end

      dst
    end
    
    def identify
      meta = {}
      command = "ffmpeg -i #{File.expand_path(@file.path)} 2>&1"
      Paperclip.log(command)
      ffmpeg = IO.popen(command)
      ffmpeg.each("\r") do |line|
        if line =~ /((\d*)\s.?)fps,/
          meta[:fps] = $1.to_i
        end
        # Matching lines like:
        # Video: h264, yuvj420p, 640x480 [PAR 72:72 DAR 4:3], 10301 kb/s, 30 fps, 30 tbr, 600 tbn, 600 tbc
        if line =~ /Video:(.*)/
          v = $1.to_s.split(',')
          size = v[2].strip!.split(' ').first
          meta[:size] = size.to_s
          meta[:aspect] = size.split('x').first.to_f / size.split('x').last.to_f
        end
        # Matching Duration: 00:01:31.66, start: 0.000000, bitrate: 10404 kb/s
        if line =~ /Duration:(\s.?(\d*):(\d*):(\d*\.\d*))/
          meta[:length] = $2.to_s + ":" + $3.to_s + ":" + $4.to_s
        end
      end
      meta
    end
  end
  
  class Attachment
    def meta
      instance_read(:meta)
    end
  end
end