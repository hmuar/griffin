class @SessionHost

  constructor: (@game) ->
    # XXX sessionid is very important.  A unique sessionid should be assigned
    # to each human player in a multiplayer game, and the other players'
    # sessionids must be kept hidden on the server.  When the server sends
    # commands to the server, they must send their sessionid for verification.
    # The server then processes the command if the player's sessionid matches
    # that of the active player.  In fact, if the player's sessionid does not
    # match the in-game player's, don't send anything to the server at all to
    # conserve bandwidth.
    @sessionid = null
    @players = []   # array of Player objects
    @player_delays = {}  # dict of delays (value) where key is player id
    @bullets = []
    @active_player = null
    @turn_time_remaining = 0
    # XXX move all these to HUD class later
    @turnText = null

    # Add all sprites in play to this group so that the GameUI's group sits
    # on top of all of them
    @playgroup = null

    # p2.js world which runs our physics simulation
    @p2world = null

    # game camera
    @gcamera = null

    @endingTurn = false
    @endTurnTimer = 0
    @gameOver = false

  initialize: (player_ids) ->

    GameInputs.shost = this
    GameInputs.setupInputs()
    GameUI.initialize(this)
    
    # for particle physics
    @game.physics.startSystem(Phaser.Physics.ARCADE)

    # Setup background and world
    @playgroup = @game.add.group()
    @background = new Phaser.Sprite(@game, 0, 0, 'background')
    @playgroup.add(@background)
    @game.camera.scale.set(
      GameConstants.cameraScale,GameConstants.cameraScale)

    # This is our own game logic World class, not to be confused with
    # Phaser's built in @game.world
    @world = WorldCreator.loadFromImage(this)
    # world will set bounds of the game, from that need to set background
    # scale to the max scale of world bounds
    bgX = @game.world.width / @background.width / GameConstants.cameraScale
    bgY = @game.world.height / @background.height / GameConstants.cameraScale
    @background.scale.set(bgX, bgY)

    # This is the p2 physics simulated world, which is where the
    # physics representations of the players and bullets etclive.
    # p2world holds the ground truth of where objects in the scene
    # live, we only use Phaser for drawing sprites at their locations.
    @p2world = new p2.World()
    @p2world.gravity = [0,0]

    num_players = 0
    for id in player_ids
      # instantiate player objects and add to @players list
      player = new Player(this)
      player.initialize(this, id, 500 + num_players*300, 800,
        GameConstants.playerScale, 0)
      player.initHealth(100)
      @players.push player

      # for each player add a delay wait entry
      @player_delays[id] = 0

      num_players++

    # Disable player-to-player p2 body collisions.  For every pairing of 
    # players, disable collisions
    if num_players > 1
      i = 0
      while true
        for j in [i..num_players-1]
          if j != i
            #console.log 'disable ', i, ' ', j
            @p2world.disableBodyCollision(@players[i].entity.p2body, @players[j].entity.p2body)
        i += 1
        if i == num_players
          break

    @gcamera = new GameCamera(this)
    @gcamera.initialize(1.0)
    # XXX Move these to UI class
    @turnText = new Phaser.Text(@game, 16, 16, 'Turn')
    @gcamera.addFixedSprite(@turnText)
    @endPlayerTurn()

    GameUI.bringToTop()

    #@game.input.keyboard.addKey(Phaser.Keyboard.SPACEBAR).onDown.add(@playerFire, this)
    #@game.input.keyboard.addKey(Phaser.Keyboard.Z).onDown.add(@toggleZoom, this)

  update: (dt) ->

    # step p2world for physics simulation to occur
    @p2world.step(dt)
    
    if @gameOver
      return

    for player in @players
      player.update(@world)

    for bullet in @bullets
      if bullet != null
        bullet.update(@world)

    @gcamera.update(dt)

    if @turn_time_remaining > 0
      oldtime = Math.floor(@turn_time_remaining)
      @turn_time_remaining -= dt
      newtime = Math.ceil(@turn_time_remaining)
      if oldtime != newtime
        GameUI.updateTurnTime(newtime)
      if @turn_time_remaining <= 0
        GameUI.updateTurnTime(0)
        # If time ran out but there is a bullet still alive, let the bullet
        # end the player's turn upon its death
        if @active_player != null
          playerBulletAlive = false
          for bullet in @bullets
            if bullet.player == @active_player
              playerBulletAlive = true
              break
          if !playerBulletAlive
            @active_player.endTurn()
      
    if @endingTurn
      @endTurnTimer -= dt
      # XXX In future, need to also check if all players and bullets have 
      # stopped moving before ending turn
      if @endTurnTimer <= 0
        @endingTurn = false
        @endTurnTimer = 0
        @endPlayerTurn()
      return

    GameInputs.update(dt)

  testExplosion: () ->
    x = @game.input.activePointer.worldX
    y = @game.input.activePointer.worldY
    ExplosionFactory.createPebbleBasic(@game, x, y)
    #ExplosionFactory.createExplosionBasic(@game, x, y)
    null

  render: ->
    @world.render()

  playerMoveLeft: (dt) ->
    @active_player.moveLeft(dt, @world)
    GameUI.updateMoveBar(
      1.0 - @active_player.cur_movement / @active_player.max_movement)
  playerMoveRight: (dt) ->
    @active_player.moveRight(dt, @world)
    GameUI.updateMoveBar(
      1.0 - @active_player.cur_movement / @active_player.max_movement)
  playerAimUp: (dt) ->
    @active_player.aimUp(dt)
  playerAimDown: (dt) ->
    @active_player.aimDown(dt)
  playerChargeShot: (dt) ->
    @active_player.chargeShot(dt)
    GameUI.updateShotBar(
      @active_player.shot_charge / @active_player.max_shot_charge)
  playerFire: () ->
    @active_player.fire()

  tryEndPlayerTurn: ->
    if @active_player == null
      return

    @player_delays[@active_player.id] += 100
    @active_player.active = false
    @active_player = null
    # Kick off variable and timer to start end turn countdown
    @endingTurn = true
    @endTurnTimer = GameConstants.endTurnWaitTime

  endPlayerTurn: ->
    console.log "end player turn" 

    next_player_id = -1
    min_delay = 99999

    for id, delay of @player_delays
      if delay < min_delay
        min_delay = delay
        next_player_id = id

    # Note to self:
    # don't clear next_player_id's delay!  Should be cumulative thru turns

    for player in @players
      player.hideUI()   # hides aiming device, UI displays, etc
      if player.id == next_player_id
        @active_player = player
        # XXX Will this reference the actual player, or a copy of it for the 
        # loop?
        @active_player.active = true
        @active_player.showUI()
        @active_player.initTurn()
        @endTurnRefreshUI()

    @gcamera.follow(@active_player.sprite)
    @gcamera.easeTo(@active_player.getX() - @game.width/2, @active_player.getY() - @game.height/2)

    @turnText.text = 'Player ' + next_player_id + ' turn'
    @turn_time_remaining = GameConstants.turnTime

  endTurnRefreshUI: ->
    GameUI.updateMoveBar(
      1.0 - @active_player.cur_movement / @active_player.max_movement)
    GameUI.updateShotBar(0)
    GameUI.refreshShotSave(@active_player.last_charge / @active_player.max_shot_charge)
    GameInputs.spaceIsDown = false

  removePlayer: (removePlayer) ->
    if @active_player == removePlayer
      @active_player = null
    # first remove reference to player
    remaining_players = []
    for player in @players
      if player != removePlayer
        remaining_players.push(player)
    @players = remaining_players

    if @players.length == 1
      @gameOver = true
      @gameOverText = new Phaser.Text(@game, 200, 200, 'Game Over')
      @gcamera.addFixedSprite(@gameOverText)
      return

    # then remove player entry in delay queue
    new_delays = {}
    for id, delay of @player_delays
      if id != removePlayer.id
        new_delays[id] = delay
    @player_delays = new_delays

  removeBullet: (removeBullet) ->
    remaining_bullets = []
    for bullet in @bullets
      if bullet != removeBullet
        remaining_bullets.push(bullet)      
    @bullets = remaining_bullets
    

    


