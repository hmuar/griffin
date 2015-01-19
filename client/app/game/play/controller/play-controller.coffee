mInput = require 'input/game-input'
mUi = require 'ui/game-ui'
mWorld = require 'world/world'
mConfig = require 'world/game-config'
mCam = require 'world/game-camera'
mPlayer = require 'entity/player'
State = require 'controller/state'

class PlayController

  constructor: (@game, @sessionController) ->
    
    @sessionId = null  # The player's secret session id, known only to him
    @players = []   # array of Player objects
    @player_delays = {}  # dict of delays (value) where key is player id
    @bullets = []
    @active_player = null
    @turn_time_remaining = 0

    # Add all sprites in play to this group so that the mUi.GameUI's group sits
    # on top of all of them
    @playgroup = null

    # p2.js world which runs our physics simulation
    @p2world = null

    # game camera
    @gcamera = null

    # @endingTurn = false
    @endTurnTimer = 0
    @gameOver = false
    @setState(State.INIT)

  setState: (newState) ->
    @state = newState

  getState: ->
    return @state

  initialize: (initConfig) ->
    @setState(State.SETUP)
    mInput.GameInput.controller = this
    mInput.GameInput.setupInputs()
    mUi.GameUI.initialize(this)
    
    # for particle physics
    @game.physics.startSystem(Phaser.Physics.ARCADE)

    # Setup background and world
    @playgroup = @game.add.group()
    @background = new Phaser.Sprite(@game, 0, 0, 'background')
    @playgroup.add(@background)
    @game.camera.scale.set(
      mConfig.GameConstant.cameraScale,
      mConfig.GameConstant.cameraScale
      )

    # This is our own game logic World class, not to be confused with
    # Phaser's built in @game.world
    @world = mWorld.WorldCreator.loadFromImage(this, 'world_bridge')
    @world.setSpawnOrder([2,0,1,3])
    # world will set bounds of the game, from that need to set background
    # scale to the max scale of world bounds
    bgX = @game.world.width / @background.width / mConfig.GameConstant.cameraScale
    bgY = @game.world.height / @background.height / mConfig.GameConstant.cameraScale
    @background.scale.set(bgX, bgY)

    # This is the p2 physics simulated world, which is where the
    # physics representations of the players and bullets etclive.
    # p2world holds the ground truth of where objects in the scene
    # live, we only use Phaser for drawing sprites at their locations.
    @p2world = new p2.World()
    @p2world.gravity = [0,0]

    num_players = 0
    
    # initConfig
    # {
    #    init: 
    #      id0: 
    #        pos: [x0, y0]
    #      id1:
    #        pos: [x1, y1]
    #    myid: "Awkjhds72jds2sd"
    #    turn: "Awkjhds72jds2sd"
    # }

    @sessionId = initConfig['myid']

    for own id,playerConfig of initConfig['init']
      # for now just set the name same as id
      name = id
      spawnPos = playerConfig['pos']
      if spawnPos == undefined or spawnPos == null
        throw new Error "spawn position not found for player #{id}"
      # instantiate player objects and add to @players list
      player = new mPlayer.Player(this)
      player.initialize(this, id, spawnPos[0], spawnPos[1],
        mConfig.GameConstant.playerScale, 0)
      player.initHealth(200)
      player.setName(name)
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
            @p2world.disableBodyCollision(@players[i].entity.p2body, @players[j].entity.p2body)
        i += 1
        if i == num_players
          break

    @gcamera = new mCam.GameCamera(this)
    @gcamera.initialize(1.0)
    @endPlayerTurn()
    mUi.GameUI.bringToTop()
    #@game.input.keyboard.addKey(Phaser.Keyboard.SPACEBAR).onDown.add(@playerFire, this)
    #@game.input.keyboard.addKey(Phaser.Keyboard.Z).onDown.add(@toggleZoom, this)

  changeTurn: (turnConfig) ->
    activeId = turnConfig['tid']
    if @sessionId == activeId
      console.log 'MY TURN'
      @setState(State.INPUT)
    else
      console.log 'NOT MY TURN'
      @setState(State.TURN_WAIT)

  update: (dt) ->
    # step p2world for physics simulation to occur
    @p2world.step(dt)
    
    if @gameOver
      return

    for player in @players
      player.update(dt, @world)

    for bullet in @bullets
      if bullet != null
        bullet.update(@world)

    @gcamera.update(dt)

    if @turn_time_remaining > 0
      oldtime = Math.floor(@turn_time_remaining)
      @turn_time_remaining -= dt
      newtime = Math.ceil(@turn_time_remaining)
      if oldtime != newtime
        mUi.GameUI.updateTurnTime(newtime)
      if @turn_time_remaining <= 0
        mUi.GameUI.updateTurnTime(0)
        # If time ran out but there is a bullet still alive, let the bullet
        # end the player's turn upon its death
        if @active_player != null
          if !@active_player.hasAliveBullets()
            @active_player.endTurn()

    # if @endingTurn
    if @getState() == State.REACT
      @endTurnTimer -= dt
      # XXX In future, need to also check if all players and bullets have 
      # stopped moving before ending turn
      if @endTurnTimer <= 0
        # @endingTurn = false
        @endTurnTimer = 0
        @endPlayerTurn()
      return

    mInput.GameInput.update(dt)

  testExplosion: ->
    x = @game.input.activePointer.worldX
    y = @game.input.activePointer.worldY
    ExplosionFactory.createPebbleBasic(@game, x, y)
    #ExplosionFactory.createExplosionBasic(@game, x, y)
    null

  render: ->
    @world.render()

  playerMoveLeft: (dt) ->
    @active_player.moveLeft(dt, @world)
    mUi.GameUI.updateMoveBar(
      1.0 - @active_player.cur_movement / @active_player.max_movement)

  playerMoveRight: (dt) ->
    @active_player.moveRight(dt, @world)
    mUi.GameUI.updateMoveBar(
      1.0 - @active_player.cur_movement / @active_player.max_movement)

  playerAimUp: (dt) ->
    @active_player.aimUp(dt)

  playerAimDown: (dt) ->
    @active_player.aimDown(dt)

  playerChargeShot: (dt) ->
    @active_player.chargeShot(dt)
    mUi.GameUI.updateShotBar(
      @active_player.shot_charge / @active_player.max_shot_charge)

  playerFire: ->
    @active_player.fire()

  playerMoveCamera: (x, y) ->
    @gcamera.playerMoveCamera(x, y)

  playerReleaseCamera: ->
    @gcamera.playerReleaseCamera()

  playerSetWeapon: (num) ->
    # XXX Currently implementation won't work for multiplayer.  Need to 
    # associate Player objects with sessionid of human players, then set the
    # Player with corresponding human sessionid's weapon.
    # For now just set active player while it's "single player"
    if @active_player == null
      return
    @active_player.setWeapon(num)

  tryEndPlayerTurn: (died=false) ->
    if @active_player == null
      return

    if died
      @removePlayer(@active_player)
    else
      @player_delays[@active_player.id] += 100
      @active_player.active = false

    @active_player = null
    # Kick off variable and timer to start end turn countdown
    @setState(State.REACT)
    # @endingTurn = true
    @endTurnTimer = mConfig.GameConstant.endTurnWaitTime

  endPlayerTurn: ->
    @setState(State.CLEANUP)
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

    mUi.GameUI.updateTurnText('Player ' + next_player_id + ' turn')
    @turn_time_remaining = mConfig.GameConstant.turnTime

  endTurnRefreshUI: ->
    mUi.GameUI.updateMoveBar(
      1.0 - @active_player.cur_movement / @active_player.max_movement)
    mUi.GameUI.updateShotBar(0)
    mUi.GameUI.refreshShotSave(@active_player.last_charge / @active_player.max_shot_charge)
    mInput.GameInput.spaceIsDown = false
    mUi.GameUI.refreshWeaponUI(@active_player.wep_num)

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


exports.PlayController = PlayController