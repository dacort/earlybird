# TODO
#  switch to xauth
#    ask for u/p once, then save token (https://gist.github.com/304123/17685f51b5ecad341de9b58fb6113b4346a7e39f)


$KCODE = 'u'

%w[rubygems net/http json twitter-text term/ansicolor twitter highline/import].each{|l| require l}

include Term::ANSIColor

class EarlyBird

  def initialize(user, pass, track)
    httpauth = Twitter::HTTPAuth.new(user, pass)
    @client = Twitter::Base.new(httpauth)
    @friends = []
    @track = track
  end

  def highlight(text)
    text.gsub(Twitter::Regex::REGEXEN[:extract_mentions], ' ' + cyan('@\2')).
      gsub(Twitter::Regex::REGEXEN[:auto_link_hashtags], ' ' + yellow('#\3'))
  end

  def search_highlight(text)
    highlight(text)
    @track.inject(text) do |newtext, term|
      newtext.gsub(term, green(term))
    end
  end

  def print_tweet(sn, text)
    print sn(sn) , ': ', highlight(text), "\n"
  end

  def print_search(sn, text)
    print green(bold(sn)) , ': ', search_highlight(text), "\n"
  end

  def sn(sn)
    red(bold(sn))
  end

  def user_and_status(user_id, status_id)
    u = @client.user(user_id)
    s = @client.status(status_id)
    [u, s]
  rescue Twitter::General => e
    raise e unless e.message =~ /403/
  end

  def process(data)
    if data['friends']
      # initial dump of friends
      @friends = data['friends']
    elsif data['text'] #tweet
      if @friends.include?(data['user']['id'])
        print_tweet(data['user']['screen_name'], data['text'])
      else
        print ' search result: '  + sn(data['user']['screen_name']) + "\n"
        print "\t"
        print_search(data['user']['screen_name'], data['text'])
      end
    elsif data['event']
      case data['event']
      when 'favorite', 'unfavorite'
        u, s = user_and_status(data['source']['id'], data['target_object']['id'])
        print sn(u.screen_name), ' favorited: ' + "\n"
        print "\t"
        print_tweet(s.user.screen_name, s.text)
      when 'retweet'
        u, s = user_and_status(data['source']['id'], data['target_object']['id'])
        print sn(u.screen_name), " #{data['event']}d: " + "\n"
        print "\t"
        print_tweet(s.user.screen_name, s.text)
      when 'unfollow', 'follow', 'block'
        s = @client.user(data['source']['id'])
        t = @client.user(data['target']['id'])
        print sn(s['screen_name']), ' ', data['event'], 'ed', ' ', sn(t['screen_name']), "\n"
      else
        puts "unknown event: #{data['event']}"
        puts data
      end
    elsif data['delete']
      # ignore deletes
    else
      puts 'unknown message'
      puts data
      puts '===='
    end
  rescue Twitter::RateLimitExceeded
    puts "event dropped due to twitter rate limit (reset in #{@client.rate_limit_status['reset_time_in_seconds'] - Time.now} seconds)"
    p @client.rate_limit_status
  end
end

class Hose
  KEEP_ALIVE  = /\A3[\r][\n][\n][\r][\n]/
  DECHUNKER   = /\A[0-F]+[\r][\n]/
  NEWLINE     = /[\n]/
  CRLF        = /[\r][\n]/
  EOF         = /[\r][\n]\Z/

  def unchunk(data)
    data.gsub(/\A[0-F]+[\r][\n]/, '')
  end

  def keep_alive?(data)
    data =~ KEEP_ALIVE
  end

  def extract_json(lines)
    # lines.map {|line| Yajl::Stream.parse(StringIO.new(line)).to_mash rescue nil }.compact
    lines.map {|line| JSON.parse(line).to_hash rescue nil }.compact
  end

  def run(user, pass, host, path, debug=false)
    if debug
      $stdin.each_line do |line|
        process(line)
      end
    else
      while true
        begin
          Net::HTTP.start(host) {|http|
            req = Net::HTTP::Get.new(path)
            req.basic_auth user, pass
            http.request(req) do |response|
              buffer = ''
              response.read_body do |data|
                unless keep_alive?(data)
                  buffer << unchunk(data)

                  if buffer =~ EOF
                    lines = buffer.split(CRLF)
                    buffer = ''
                  else
                    lines = buffer.split(CRLF)
                    buffer = lines.pop
                  end

                  extract_json(lines).each {|line| yield(line)}
                end
              end
            end
          }
        rescue Errno::ECONNRESET
          puts "disconnected from streaming api, reconnecting..."
          sleep 5
        end
      end
    end
  end
end

print "username: "
# had to qualify by $stdin because it wanted to do gets from ARGV?
user = $stdin.gets.strip
pass = ask("Enter your password:  ") { |q| q.echo = '*' }


track = ARGV.reject{|t| t == 'debug'}.join(' ').split(',')
url = '/2b/user.json'
if track.length > 0
  url << "?track=" + CGI::escape(track.join(','))
end
puts "connecting to #{url}"
eb = EarlyBird.new(user, pass, track)
Hose.new.run(user, pass, 'betastream.twitter.com', url, ARGV.first == 'debug'){|line| eb.process(line)}