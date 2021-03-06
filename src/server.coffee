{Promise, fs} = require './utils/dependencies'
striptags = require 'striptags'
{loadPlugins, callPluginMethod, loadPost, parsePost, transformExpressApp} = require './plugin/plugin'
express = require 'express'
RSS = require 'rss'
{renderIndex, renderPost} = require './template'
configuration = require './utils/configuration'
configuration.on 'change', (config) ->
  checkConfig config

posts = {}
postsArr = []
postsByTags = {}
feed = null

# Cache the rendering results
cache = {}
setupCache = (app) ->
  app.use (req, res, next) ->
    if req.method isnt 'GET'
      next()
    else if cache[req.path]?
      res.send cache[req.path] # Cache hit!
    else
      _send = res.send.bind res
      res.send = (body) ->
        cache[req.path] = body
        _send body
      next()

clearCache = -> cache = {}

start = ->
  return if not checkConfig configuration.config
  app = express()
  app.use '/assets', express.static 'template/assets'
  setupCache app
  app.get '/', (req, res) ->
    renderIndex postsArr, 0
      .then (index) -> res.send index
  app.get '/page/:id(\\d+)', (req, res) ->
    promise = renderIndex postsArr, parseInt req.params.id
    if not promise?
      res.sendStatus 404
    else
      promise.then (page) -> res.send page
  app.get '/tag/:name', (req, res) ->
    if not postsByTags[req.params.name]?
      res.sendStatus 404
    else
      renderIndex postsByTags[req.params.name], 0, "/tag/#{req.params.name}/"
        .then (index) -> res.send index
  app.get '/tag/:name/page/:id(\\d+)', (req, res) ->
    if not postsByTags[req.params.name]?
      res.sendStatus 404
    else
      promise = renderIndex postsByTags[req.params.name], parseInt req.params.id, "/tag/#{req.params.name}/"
      if not promise?
        res.sendStatus 404
      else
        promise.then (page) -> res.send page
  app.get '/rss/', (req, res) ->
    if feed?
      res.set('Content-Type', 'application/rss+xml')
      res.send feed.xml indent: true
    else
      res.sendStatus 404

  # Allow transforming before we set up the wildcard rule
  transformExpressApp app
    .then ->
      app.get '/*', (req, res) ->
        if not req.path.endsWith '/'
          res.redirect 301, req.path + '/'
          return
        postName = req.params[0].replace(/\/$/, '')
        if posts[postName]?
          renderPost posts[postName]
            .then (content) -> res.send content
        else
          res.sendStatus 404

      app.listen configuration.config.port, '127.0.0.1', ->
        console.log "Listening on 127.0.0.1:#{configuration.config.port}"

checkConfig = (config) ->
  if not (config.title? and config.url? and config.description?)
    console.error 'Please provide at least `title` `url` and `description`'
    return false
  if not config.posts? or config.posts.length is 0
    console.error 'No posts found'
    return false
  if not config.port?
    config.port = "2333"
  if isNaN parseInt config.port
    console.error "Invalid port #{config.port}"
    return false
  if not config.posts_per_page?
    config.posts_per_page = 5
  if isNaN parseInt config.posts_per_page
    console.error "Invalid number #{config.posts_per_page}"
    return false
  loadPlugins config
  reloadPosts()
  true

reloadPosts = ->
  newPosts = {}
  newPostsByTags = {}
  Promise.map configuration.config.posts, (item) ->
    loadPost item
  .map parsePost
  .map (data) ->
    callPluginMethod "parseContent#{data.parser}", [data.content]
      .then (content) ->
        data.content = content
        data.contentStripped = striptags content
        return data
  .each (item) ->
    newPosts[item.url] = item

    if item.tags? and item.tags.length > 0
      item.tags.forEach (it) ->
        if not newPostsByTags[it]?
          newPostsByTags[it] = []
        newPostsByTags[it].push item
  .all()
  .then ->
    posts = newPosts
    postsArr = (post for _, post of posts when not post.hide)
    postsByTags = newPostsByTags

    feed = new RSS
      title: configuration.config.title
      description: configuration.config.description
      site_url: configuration.config.url
      feed_url: configuration.config.url + "/rss/"

    arr = postsArr
    if arr.length > 5
      arr = arr[0..4]
    arr.forEach (it) ->
      feed.item
        title: it.title
        description: it.content
        date: it.date
        url: configuration.config.url + "/" + it.url
  .then -> clearCache()
  .catch (e) ->
    console.error e
    process.exit 1

module.exports =
  start: start