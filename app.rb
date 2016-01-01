require 'digest/sha1'

class RankingApp < Sinatra::Base
  configure :development do
    Bundler.require :development
    register Sinatra::Reloader
  end

  get "/" do
    send_file File.join('index.html')
  end

  get "/ranking" do
    url = params[:url]
    unless url
      halt 400, 'url required'
    end

    syntax = 'hatena'
    syntax = params[:syntax] if ['hatena', 'markdown'].include?(params[:syntax])

    cache = Dalli::Client.new

    cache_key = Digest::SHA1.hexdigest("#{syntax}#{url}")
    content = cache.get(cache_key)
    return content if content

    ranking = Ranking.new(url)
    content = ranking.report(syntax)

    cache.set(cache_key, content, 3600)

    content
  end
end

class Ranking
  def initialize(blog_uri)
    @blog_uri = blog_uri
  end

  def report(syntax)
    entry_uris = get_entry_uris
    counts = get_counts(entry_uris)
    total = counts.values.reduce{|a, b| a + b }
    sorted_entry_uris = entry_uris.sort_by{|uri| -counts[uri] }.delete_if{|uri| counts[uri] == 0 }[0...100]

    template = Erubis::Eruby.new open('a.erb').read
    template.result(
      blog_uri: @blog_uri,
      items: sorted_entry_uris,
      syntax: syntax,
      total: total,
    )
  end

  def get_entry_uris
    uris = []
    index = Nokogiri get sitemap_index_uri
    index.search('loc').each{|loc|
      page = Nokogiri get loc.content
      page.search('url').each{|item|

        uri = item.at('loc').content
        last_mod = item.at('lastmod').content
        next unless uri.match(/\/entry\//)

        if last_mod[0..3].to_i != target_year
          return uris
        end

        uris.push uri
      }
    }
  end

  def get_counts uris
    result = {}
    uris.each_slice(50).each{|sliced|
      query = sliced.map{|uri| ['url', uri]}
      res = JSON.parse get 'http://api.b.st-hatena.com/entry.counts?' + URI.encode_www_form(query)
      result.merge!(res)
    }
    result
  end

  def get uri
    warn "get #{uri}"
    @cache ||= Dalli::Client.new
    cache_key = Digest::SHA1.hexdigest(uri)
    content = @cache.get(cache_key)
    return content if content
    warn "real get #{uri}"
    sleep 1
    result = String.new(RestClient.get(uri, :user_agent => "blog-bookmark-ranking"))
    @cache.set(cache_key, result, 3600)
    result
  end

  def sitemap_index_uri
    URI.join(@blog_uri, '/sitemap.xml').to_s
  end

  def target_year
    (Time.now - 3600*24*180).year
  end
end

url = ARGV.first

