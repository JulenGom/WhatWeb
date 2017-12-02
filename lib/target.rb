# Copyright 2009, 2017 Andrew Horton and Brendan Coles
#
# This file is part of WhatWeb.
#
# WhatWeb is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 2 of the License, or at your option) any later version.
#
# WhatWeb is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with WhatWeb.  If not, see <http://www.gnu.org/licenses/>.

# try to make a new Target object, may return nil
def prepare_target(url)
  Target.new(url)
rescue => err
  error("Prepare Target Failed - #{err}")
  nil
end

def make_target_list(cmdline_args, inputfile = nil, _pluginlist = nil)
  url_list = cmdline_args

  # read each line as a url, skipping lines that begin with a #
  if !inputfile.nil? && File.exist?(inputfile)
    pp "loading input file: #{inputfile}" if $verbose > 2
    url_list += File.open(inputfile).readlines.each(&:strip!).delete_if { |line| line =~ /^#.*/ }.each { |line| line.delete!("\n") }
  end

  genrange = url_list.map do |x|
    range = nil
    # Parse IP ranges
    if x =~ /^[0-9\.\-\/]+$/ && x !~ /^[\d\.]+$/
      begin
        # CIDR notation
        if x =~ %r{\d+\.\d+\.\d+\.\d+/\d+$}
          range = IPAddr.new(x).to_range.map(&:to_s)
        # x.x.x.x-x
        elsif x =~ /^(\d+\.\d+\.\d+\.\d+)-(\d+)$/
          start_ip = IPAddr.new(Regexp.last_match(1), Socket::AF_INET)
          end_ip   = IPAddr.new("#{start_ip.to_s.split('.')[0..2].join('.')}.#{Regexp.last_match(2)}", Socket::AF_INET)
          range = (start_ip..end_ip).map(&:to_s)
        # x.x.x.x-x.x.x.x
        elsif x =~ /^(\d+\.\d+\.\d+\.\d+)-(\d+\.\d+\.\d+\.\d+)$/
          start_ip = IPAddr.new(Regexp.last_match(1), Socket::AF_INET)
          end_ip   = IPAddr.new(Regexp.last_match(2), Socket::AF_INET)
          range = (start_ip..end_ip).map(&:to_s)
        end
      rescue
        # Something went horribly wrong parsing the target IP range
        raise 'Error parsing target IP range'
      end
    end
    range
  end.compact.flatten

  url_list = url_list.select { |x| !(x =~ /^[0-9\.\-*\/]+$/) || x =~ /^[\d\.]+$/ }
  url_list += genrange unless genrange.empty?

  # make urls friendlier, test if it's a file, if test for not assume it's http://
  # http, https, ftp, etc
  push_to_urllist = []
  url_list = url_list.map do |x|
    if File.exist?(x)
      x
    else
      # use url pattern
      x = $URL_PATTERN.gsub('%insert%', x) if $URL_PATTERN
      # add prefix & suffix
      x = $URL_PREFIX + x + $URL_SUFFIX

      # need to move this into a URI parsing function
      #
      # check for URI prefix
      if x !~ /^[a-z]+:\/\//
        # add missing URI prefix
        x.sub!(/^/, 'http://')
      end

      # is it a valid domain?
      begin
        domain = Addressable::URI.parse(x)
        # check validity
        raise 'Unable to parse invalid target. No hostname.' if domain.host.empty?

        # convert IDN domain
        x = domain.normalize.to_s if domain.host !~ /^[a-zA-Z0-9\.:\/]*$/
      rescue
        # if it fails it's not valid
        x = nil
        error("Unable to parse invalid target #{x}")
      end
      # return x
      x
    end
  end

  url_list += push_to_urllist unless push_to_urllist.empty?

  # compact removes nils
  url_list = url_list.flatten.compact # .sort.uniq
end

# backwards compatible convenience method for plugins to use
def open_target(url)
  newtarget = Target.new(url)
  begin
    newtarget.open
  rescue => err
    error("ERROR Opening: #{newtarget} - #{err}")
  end
  # it doesn't matter if the plugin only pulls 5 instead of 6 variables
  [newtarget.status, newtarget.uri, newtarget.ip, newtarget.body, newtarget.headers, newtarget.raw_headers]
end

def decode_html_entities(s)
  t = s.dup
  html_entities = { '&quot;' => '"', '&apos;' => "'", '&amp;' => '&', '&lt;' => '<', '&gt;' => '>' }
  html_entities.each_pair { |from, to| t.gsub!(from, to) }
  t
end

### matching

# fuzzy matching ftw
def make_tag_pattern(b)
  # remove stuff between script and /script
  # don't bother with  !--, --> or noscript and /noscript
  inscript = false

  b.scan(/<([^\s>]*)/).flatten.map do |x|
    x.downcase!
    r = nil
    r = x if inscript == false
    inscript = true if x == 'script'
    (inscript = false; r = x) if x == '/script'
    r
  end.compact.join(',')
end

# some plugins want a random string in URLs
def randstr
  rand(36**8).to_s(36)
end

def match_ghdb(ghdb, body, _meta, _status, base_uri)
  # this could be made faster by creating code to eval once for each plugin

  pp 'match_ghdb', ghdb if $verbose > 2

  # take a GHDB string and turn it into code to be evaluated
  matches = [] # fill with true or false. succeeds if all true
  s = ghdb

  # does it contain intitle?
  if s =~ /intitle:/i
    # extract either the next word or the following words enclosed in "s, it can't possibly be both
    intitle = (s.scan(/intitle:"([^"]*)"/i) + s.scan(/intitle:([^"]\w+)/i)).to_s
    matches << ((body =~ /<title>[^<]*#{Regexp.escape(intitle)}[^<]*<\/title>/i).nil? ? false : true)
    # strip out the intitle: part
    s = s.gsub(/intitle:"([^"]*)"/i, '').gsub(/intitle:([^"]\w+)/i, '')
  end

  if s =~ /filetype:/i
    filetype = (s.scan(/filetype:"([^"]*)"/i) + s.scan(/filetype:([^"]\w+)/i)).to_s
    # lame method: check if the URL ends in the filetype
    unless base_uri.nil?
      unless base_uri.path.split('?')[0].nil?
        matches << ((base_uri.path.split('?')[0] =~ /#{Regexp.escape(filetype)}$/i).nil? ? false : true)
      end
    end
    s = s.gsub(/filetype:"([^"]*)"/i, '').gsub(/filetype:([^"]\w+)/i, '')
  end

  if s =~ /inurl:/i
    inurl = (s.scan(/inurl:"([^"]*)"/i) + s.scan(/inurl:([^"]\w+)/i)).flatten
    # can occur multiple times.
    inurl.each { |x| matches << ((base_uri.to_s =~ /#{Regexp.escape(x)}/i).nil? ? false : true) }
    # strip out the inurl: part
    s = s.gsub(/inurl:"([^"]*)"/i, '').gsub(/inurl:([^"]\w+)/i, '')
  end

  # split the remaining words except those enclosed in quotes, remove the quotes and sort them

  remaining_words = s.scan(/([^ "]+)|("[^"]+")/i).flatten.compact.each { |w| w.delete!('"') }.sort.uniq

  pp 'Remaining GHDB words', remaining_words if $verbose > 2

  remaining_words.each do |w|
    # does it start with a - ?
    if w[0..0] == '-'
      # reverse true/false if it begins with a -
      matches << ((body =~ /#{Regexp.escape(w[1..-1])}/i).nil? ? true : false)
    else
      w = w[1..-1] if w[0..0] == '+' # if it starts with +, ignore the 1st char
      matches << ((body =~ /#{Regexp.escape(w)}/i).nil? ? false : true)
    end
  end

  pp matches if $verbose > 2

  # if all matcbhes are true, then true
  if matches.uniq == [true]
    true
  else
    false
  end
end

#
# Target
#
class Target
  attr_reader :target
  attr_reader :uri, :status, :ip, :body, :headers, :raw_headers, :raw_response
  attr_reader :cookies
  attr_reader :md5sum
  attr_reader :tag_pattern
  attr_reader :is_url, :is_file
  attr_accessor :http_options

  @@meta_refresh_regex = /<meta[\s]+http\-equiv[\s]*=[\s]*['"]?refresh['"]?[^>]+content[\s]*=[^>]*[0-9]+;[\s]*url=['"]?([^"'>]+)['"]?[^>]*>/i

  def inspect
    #	"#{target} " + [@uri,@status,@ip,@body,@headers,@raw_headers,@raw_response,@cookies,@md5sum,@tag_pattern,@is_url,@is_file].join(",")
    "URI\n#{'*' * 40}\n#{@uri}" \
      "status\n#{'*' * 40}\n#{@status}" \
      "ip\n#{'*' * 40}\n#{@ip}" \
      "header\n#{'*' * 40}\n#{@headers}" \
      "cookies\n#{'*' * 40}\n#{@cookies}" \
      "raw_headers\n#{'*' * 40}\n#{@raw_headers}" \
      "raw_response\n#{'*' * 40}\n#{@raw_response}" \
      "body\n#{'*' * 40}\n#{@body}" \
      "md5sum\n#{'*' * 40}\n#{@md5sum}" \
      "tag_pattern\n#{'*' * 40}\n#{@tag_pattern}" \
      "is_url\n#{'*' * 40}\n#{@is_url}" \
      "is_file\n#{'*' * 40}\n#{@is_file}"
  end

  def to_s
    @target
  end

  def self.meta_refresh_regex
    @@meta_refresh_regex
  end

  def is_file?
    @is_file
  end

  def is_url?
    @is_url
  end

  def initialize(target = nil)
    @target = target
    @headers = {}
    @http_options = { method: 'GET' }
    #		@status=0

    @is_url = if @target =~ /^http[s]?:\/\//
                true
              else
                false
              end

    if File.exist?(@target)
      @is_file = true
      raise "Error: #{@target} is a directory" if File.directory?(@target)
      if File.readable?(@target) == false
        raise "Error: You do not have permission to view #{@target}"
      end
    else
      @is_file = false
    end

    if is_url?
      @uri = URI.parse(URI.encode(@target))

      # is this taking control away from the user?
      # [400] http://www.alexa.com  [200] http://www.alexa.com/
      @uri.path = '/' if @uri.path.empty?
    else
      # @uri=URI.parse("file://"+@target)
      @uri = URI.parse('')
    end
  end

  def open
    if is_file?
      open_file
    else
      open_url(@http_options)
    end

    ## after open
    if @body.nil?
      # Initialize @body variable if the connection is terminated prematurely
      # This is usually caused by HTTP status codes: 101, 102, 204, 205, 305
      @body = ''
    else
      @md5sum = Digest::MD5.hexdigest(@body)
      @tag_pattern = make_tag_pattern(@body)
      if @raw_headers
        @raw_response = @raw_headers + @body
      else
        @raw_response = @body
        @raw_headers = ''
        @cookies = []
      end
    end
  end

  def open_file
    # target is a file
    @body = File.open(@target).read
    if String.method_defined?(:encode)
      @body.encode!('UTF-16', 'UTF-8', invalid: :replace, replace: '')
      @body.encode!('UTF-8', 'UTF-16')
    else
      ic = Iconv.new('UTF-8', 'UTF-8//IGNORE')
      @body = ic.iconv(@body)
    end
    # target is a http packet file
    if @body =~ /^HTTP\/1\.\d [\d]{3} (.+)\r\n\r\n/m
      # extract http header
      @headers = {}
      pageheaders = body.to_s.split(/\r\n\r\n/).first.to_s.split(/\r\n/)
      @raw_headers = pageheaders.join("\n") + "\r\n\r\n"
      @status = pageheaders.first.scan(/^HTTP\/1\.\d ([\d]{3}) /).flatten.first.to_i
      @cookies = []
      for k in 1...pageheaders.length
        section = pageheaders[k].split(/:/).first.to_s.downcase
        if section =~ /^set-cookie$/i
          @cookies << pageheaders[k].scan(/:[\s]*(.+)$/).flatten.first
        else
          @headers[section] = pageheaders[k].scan(/:[\s]*(.+)$/).flatten.first
        end
      end
      @headers['set-cookie'] = @cookies.join("\n") unless @cookies.nil? || @cookies.empty?
      # extract html source
      if @body =~ /^HTTP\/1\.\d [\d]{3} .+?\r\n\r\n(.+)/m
        @body = @body.scan(/^HTTP\/1\.\d [\d]{3} .+?\r\n\r\n(.+)/m).flatten.first
      end
    end
  rescue => err
    raise
  end

  def open_url(options)
    begin
      @ip = Resolv.getaddress(@uri.host)
    rescue => err
      raise
    end

    begin
      if $USE_PROXY == true
        http = ExtendedHTTP::Proxy($PROXY_HOST, $PROXY_PORT, $PROXY_USER, $PROXY_PASS).new(@uri.host, @uri.port)
      else
        http = ExtendedHTTP.new(@uri.host, @uri.port)
      end

      # set timeouts
      http.open_timeout = $HTTP_OPEN_TIMEOUT
      http.read_timeout = $HTTP_READ_TIMEOUT

      # if it's https://
      # i wont worry about certificates, verfication, etc
      if @uri.class == URI::HTTPS
        http.use_ssl = true
        OpenSSL::SSL::SSLContext::DEFAULT_PARAMS[:ciphers] = 'TLSv1:TLSv1.1:TLSv1.2:SSLv3:SSLv2'
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      getthis = @uri.path + (@uri.query.nil? ? '' : '?' + @uri.query)
      req = nil

      if options[:method] == 'GET'
        req = ExtendedHTTP::Get.new(getthis, $CUSTOM_HEADERS)
      end
      if options[:method] == 'HEAD'
        req = ExtendedHTTP::Head.new(getthis, $CUSTOM_HEADERS)
      end
      if options[:method] == 'POST'
        req = ExtendedHTTP::Post.new(getthis, $CUSTOM_HEADERS)
        req.set_form_data(options[:data])
      end

      req.basic_auth $BASIC_AUTH_USER, $BASIC_AUTH_PASS if $BASIC_AUTH_USER

      res = http.request(req)

      @raw_headers = http.raw.join("\n")

      @headers = {}
      res.each_header { |x, y| @headers[x] = y }

      @headers['set-cookie'] = res.get_fields('set-cookie').join("\n") unless @headers['set-cookie'].nil?

      @body = res.body
      @status = res.code.to_i
      puts @uri.to_s + " [#{status}]" if $verbose > 1

    rescue => err
      raise
    end
  end

  def get_redirection_target
    newtarget_m, newtarget_h, newtarget = nil

    if @@meta_refresh_regex =~ @body
      metarefresh = @body.scan(@@meta_refresh_regex).flatten.first
      metarefresh = decode_html_entities(metarefresh)
      newtarget_m = URI.join(@target, metarefresh).to_s # this works for relative and absolute
    end

    # HTTP 3XX redirect
    if (300..399) === @status && @headers && @headers['location']
      # downcase location scheme
      location = @headers['location'].gsub(/^HTTPS:\/\//, 'https://').gsub(/^HTTP:\/\//, 'http://')
      newtarget_h = URI.join(@target, location).to_s
    end

    # if both meta refresh location and HTTP location are set, then the HTTP location overrides
    if newtarget_m || newtarget_h
      case $FOLLOW_REDIRECT
      when 'never'
        no_redirects = true # this never gets back to main loop but no prob
      when 'http-only'
        newtarget = newtarget_h
      when 'meta-only'
        newtarget = newtarget_m
      when 'same-site'
        newtarget = (newtarget_h || newtarget_m) if URI.parse((newtarget_h || newtarget_m)).host == @uri.host # defaults to _h if both are present
      when 'always'
        newtarget = (newtarget_h || newtarget_m)
      else
        error('Error: Invalid REDIRECT mode')
      end
    end
    newtarget = nil if newtarget == @uri.to_s # circular redirection not allowed

    newtarget
  end
end
