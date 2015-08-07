$LOAD_PATH.unshift File.expand_path('../../../lib/', __FILE__)

require 'sinatra/base'

require 'multi_json'
require 'oj'
require 'hashie/mash'

require 'elasticsearch'
require 'elasticsearch/model'
require 'elasticsearch/persistence'

require 'archieml'

class Storyline
  attr_reader :attributes

  def initialize(attributes={})
    @attributes = Hashie::Mash.new(attributes)
    __add_date
    # __extract_tags
    __truncate_text
    self
  end

  def method_missing(method_name, *arguments, &block)
    attributes.respond_to?(method_name) ? attributes.__send__(method_name, *arguments, &block) : super
  end

  def respond_to?(method_name, include_private=false)
    attributes.respond_to?(method_name) || super
  end

  #def tags; attributes.tags || []; end

  def to_hash
    @attributes.to_hash
  end

  #def __extract_tags
  #  tags = attributes['text'].scan(/(\[\w+\])/).flatten if attributes['text']
  #  unless tags.nil? || tags.empty?
  #    attributes.update 'tags' => tags.map { |t| t.tr('[]', '') }
  #    attributes['text'].gsub!(/(\[\w+\])/, '').strip!
  #  end
  #end

  def __add_date
    attributes['created_at'] ||=  Time.now.utc.iso8601
  end

  def __truncate_text
    attributes['text'] = attributes['text'][0...80] + ' (...)' if attributes['text'] && attributes['text'].size > 80
  end
end

class StorylineRepository
  include Elasticsearch::Persistence::Repository

  client Elasticsearch::Client.new url: ENV['ELASTICSEARCH_URL'], log: true

  index :storylines
  type  :storyline

  mapping do
    indexes :title,       analyzer: 'snowball'
    indexes :archieml,       analyzer:   'snowball'
    indexes :created_at, type: 'date'
  end

  create_index!

  def deserialize(document)
    Storyline.new document['_source'].merge('id' => document['_id'])
  end
end unless defined?(StorylineRepository)

class Application < Sinatra::Base
  enable :logging
  enable :inline_templates
  enable :method_override

  configure :development do
    enable   :dump_errors
    disable  :show_exceptions

    require  'sinatra/reloader'
    register Sinatra::Reloader
  end

  set :repository, StorylineRepository.new
  set :per_page,   25

  get '/' do
    @page  = [ params[:p].to_i, 1 ].max

    @storylines = settings.repository.search \
               query: ->(q, t) do
                query = if q && !q.empty?
                          {
                            bool: {
                              must: [
                                {
                                  query_string: {
                                    default_field: "storyline.title",
                                    query: q
                                  }
                                }
                              ]
                            }
                          }
                else
                  { match_all: {} }
                end

                query
               end.(params[:q], params[:t]),

               sort: [{created_at: {order: 'desc'}}],

               size: settings.per_page,
               from: settings.per_page * (@page-1),

               highlight: { fields: { text: { fragment_size: 0, pre_tags: ['<em class="hl">'],post_tags: ['</em>'] } } }

    erb :index
  end

  post '/' do
    unless params[:archieml].empty?
      @storyline = Storyline.new params
      settings.repository.save(@storyline, refresh: true)
    end

    redirect back
  end

  get '/new' do
    erb :new
  end

  get '/:id' do |id|
    @storyline = settings.repository.find(id)
    erb :show
  end

  put '/:id' do |id|
    settings.repository.update id: id, title: params[:title], archieml: params[:archieml]
    redirect back
  end

  delete '/:id' do |id|
    settings.repository.delete(id, refresh: true)
    redirect back
  end
end

Application.run! if $0 == __FILE__

__END__

@@ layout
<!DOCTYPE html>
<html>
<head>
  <title>Storylines</title>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
  <style>
    body   { color: #222; background: #fff; font: normal 80%/120% 'Helvetica Neue', sans-serif; margin: 4em; position: relative; }
    header { color: #666; border-bottom: 2px solid #666;  }
    header:after { display: table; content: ""; line-height: 0; clear: both; }
    #left  { width: 20em; float: left }
    #main  { margin-left: 20em; }
    header h1 { font-weight: normal; float: left; padding: 0.4em 0 0 0; margin: 0; }
    header form { margin-left: 19.5em; }
    header form input { font-size: 120%; width: 40em; border: none; padding: 0.5em; position: relative; bottom: -0.2em; background: transparent; }
    header form input:focus { outline-width: 0; }

    #left h2 { color: #999; font-size: 160%; font-weight: normal; text-transform: uppercase; letter-spacing: -0.05em; }
    #left h2 { border-top: 2px solid #999; width: 9.4em; padding: 0.5em 0 0.5em 0; margin: 0; }
    #left textarea { font: normal 140%/140% monospace; border: 1px solid #999; padding: 0.5em; width: 12em; }
    #main textarea { font: normal 140%/140% monospace; border: 1px solid #999; padding: 0.5em; width: 100%; }
    #left form p { margin: 0; }
    #left a { color: #000; }
    #left small.c { color: #333; background: #ccc; text-align: center; min-width: 1.75em; min-height: 1.5em; border-radius: 1em; display: inline-block; padding-top: 0.25em; float: right; margin-right: 6em; }
    #left small.i { color: #ccc; background: #333; }

    #facets { list-style-type: none; padding: 0; margin: 0 0 1em 0; }
    #facets li { padding: 0 0 0.5em 0; }

    .storyline   { border-bottom: 1px solid #999; position: relative; padding: 0.5em 0; }
    .storyline p { font-size: 140%; }
    .storyline small { font-size: 70%; color: #999; }
    .storyline small.d { border-left: 1px solid #999; padding-left: 0.5em; margin-left: 0.5em; }
    .storyline em.hl { background: #fcfcad; border-radius: 0.5em; padding: 0.2em 0.4em 0.2em 0.4em; }
    .storyline strong.t { color: #fff; background: #999; font-size: 70%; font-weight: bold; border-radius: 0.6em; padding: 0.2em 0.6em 0.3em 0.7em; }
    .storyline form.add { position: absolute; bottom: 1.5em; right: 1em; }

    .pagination { color: #000; font-weight: bold; text-align: right;  }
    .pagination:visited { color: #000; }
    .pagination a        { text-decoration: none; }
    .pagination:hover a  { text-decoration: underline; }
}

  </style>
</head>
<body>
<%= yield %>
</body>
</html>

@@ index

<header>
  <h1>Storylines</h1>
  <form action="/" method='get'>
    <input type="text" name="q" value="<%= params[:q] %>" id="q" autofocus="autofocus" placeholder="type a search query and press enter..." />
  </form>
</header>

<section id="left">
  <p><a href="/">All storylines</a> <small class="c i"><%= @storylines.size if @storylines %></small></p>
</section>

<section id="main">
<% if @storylines && @storylines.empty?  %>
     <p>No storylines found.</p>
     <% elsif @storylines && @storylines.any? %>
     <% @storylines.each_with_hit do |storyline, hit|  %>
     <div class="storyline">
     <form action="/<%= storyline.id %>" method="post">
     <input type="hidden" name="_method" value="put" />
     <input type="hidden" name="title" value="<%= storyline.title %>" />
     <p>
     <strong class="t"><a href="/<%= storyline.id %>"><%= storyline.title %></a></strong>

     <textarea name="archieml" rows="15" cols="20"><%= storyline.archieml if storyline %></textarea>

     <small class="d"><%= Time.parse(storyline.created_at).strftime('%d/%m/%Y %H:%M') %></small>

     <button>Update</button>
     </p>
     </form>
     <!-- <form action="/<%= storyline.id %>" method="post"><input type="hidden" name="_method" value="delete" /><button>Delete</button></form> -->
     </div>
     <% end  %>

    <% if @storylines.size > 0 && @page.next <= @storylines.total / settings.per_page %>
      <p class="pagination"><a href="?p=<%= @page.next %>">&rarr; Load next</a></p>
    <% end %>
    <% end  %>
</section>

@@ new

<header>
  <h1>Storylines</h1>
  <form action="/" method='get'>
    <input type="text" name="q" value="<%= params[:q] %>" id="q" autofocus="autofocus" placeholder="type a search query and press enter..." />
  </form>
</header>

<section id="left">
  <p><a href="/">All storylines</a> <small class="c i"><%= @storylines.size if @storylines %></small></p>
</section>

<section id="main">
    <div class="storyline">
    <h2>Add a storyline</h2>
    <form  action="/" method='post'>
      <p><input placeholder="title" type="text" name="title" value="<%= @storyline.title if @storyline %>"></p>
      <p><textarea name="archieml" rows="5"><%= @storyline.archieml if @storyline %></textarea></p>
      <p><input type="submit" accesskey="s" value="Save" /></p>
    </form>
    </div>
</section>

@@ show

<header>
  <h1>Storylines</h1>
  <form action="/" method='get'>
    <input type="text" name="q" value="<%= params[:q] %>" id="q" autofocus="autofocus" placeholder="type a search query and press enter..." />
  </form>
</header>

<section id="left">
  <p><a href="/">All storylines</a> <small class="c i"><%= @storylines.size if @storylines %></small></p>
</section>

<section id="main">
  <div class="storyline">
    <h3><%= @storyline.title %></h3>
    <% if params[:format] && params[:format] == 'json' %>
         <p><%= Oj.dump(Archieml.load(@storyline.archieml)) if @storyline %></p>
    <% else %>
      <pre><%= @storyline.archieml if @storyline %></pre>
    <% end %>
    <small class="d"><%= Time.parse(@storyline.created_at).strftime('%d/%m/%Y %H:%M') %></small>
  </div>
</section>
