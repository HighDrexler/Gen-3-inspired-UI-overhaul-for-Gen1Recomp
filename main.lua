-- Presentation-only UI overhaul for Gen1Recomp.
-- Native gameplay, battle logic, menu input, storage logic, and TM flow are preserved.
-- Custom rendering is feature-gated and falls back to native behavior when disabled.

local BattleState = require("src.battle.BattleState")
local EngineFont = require("src.render.Font")
local Growth = require("src.pokemon.Growth")
local Menu = require("src.ui.Menu")
local StartMenu = require("src.ui.StartMenu")
local BagMenu = require("src.ui.BagMenu")
local ListMenu = require("src.ui.ListMenu")
local PartyMenu = require("src.ui.PartyMenu")
local MoveLearnMenu = require("src.ui.MoveLearnMenu")
local Strings = require("src.core.Strings")
local TextBox = require("src.render.TextBox")
local ChoiceBox = require("src.ui.ChoiceBox")
local NamingScreen = require("src.ui.NamingScreen")
local BoxMenu = require("src.ui.BoxMenu")
local ShopMenu = require("src.ui.ShopMenu")
local Boxes = require("src.pokemon.Boxes")
local QuantityBox = require("src.ui.QuantityBox")
local Evolution = require("src.pokemon.Evolution")
local BagInventory = require("src.inventory.Bag")
local ItemEffects = require("src.inventory.ItemEffects")

local State = {
  activeBattle = nil,
  activeParty = nil,
  activeTMParty = nil,
  activeItemTargetParty = nil,
  activeMoveLearn = nil,
  activeTMPromptFlow = nil,
  activeStartMenu = nil,
  activeBagMenu = nil,
  activeBagActionMenu = nil,
  activeDialogueBox = nil,
  activeChoiceBox = nil,
  activePCMenu = nil,
  activePCList = nil,
  activePCActionMenu = nil,
  activePCAccessMenu = nil,
  activeBattleMoveLearn = nil,
  activeBattleMoveParty = nil,
  activeShopMenu = nil,
  activeShopList = nil,
  activeShopQuantity = nil,
  -- Gen 2's TM/HM "forget a move" flow: see the PartyMenu.new/Game2Module.
  -- learnMoveOn/MoveDeleter2 wraps in installCoreMenuUI. activeGen2TMParty
  -- is a dedicated pointer to the Gen 2 party picker, kept alive by hand
  -- (never nulled by the generic Gen 2 state-reset block in
  -- renderHudUnderlays, which owns activeTMParty) so it survives the moment
  -- native pops it before the learn-move dialogue chain finishes.
  -- activeGen2MoveLearn spans the whole chain (announce through learn/forget);
  -- activeGen2MoveDeleter is set only while the real forget-list step itself
  -- (src/ui/gen2/MoveDeleter.lua, opts.layout=="forget") is on screen.
  activeGen2TMParty = nil,
  activeGen2MoveLearn = nil,
  activeGen2MoveDeleter = nil,
}


local modRef = nil
local GoldCompat = {
  generation = "gen1",
}

-- Engine modules are immutable for the lifetime of one Gen1Recomp process.
-- A number of presentation paths used to pcall(require) the same module every
-- draw (battle gender/type, palettes, Pokédex, Summary, Trainer Card, etc.).
-- Lua's require caches module bodies, but the repeated protected call and
-- lookup still happened on every frame. Keep one fail-soft cache here so hot
-- render paths pay that cost once without changing any fallback behavior.
GoldCompat.engineModules={}
GoldCompat.missingEngineModules={}
function GoldCompat.engineModule(name)
  local cached=GoldCompat.engineModules[name]
  if cached~=nil then return cached end
  if GoldCompat.missingEngineModules[name] then return nil end
  local ok,module=pcall(require,name)
  if ok and module~=nil then
    GoldCompat.engineModules[name]=module
    return module
  end
  GoldCompat.missingEngineModules[name]=true
  return nil
end

function GoldCompat.requiredEngineModule(name)
  local module=GoldCompat.engineModule(name)
  if module==nil then
    -- Preserve the old direct-require failure contract at call sites whose
    -- surrounding renderer uses pcall to fall back to native presentation.
    error("required engine module unavailable: "..tostring(name),2)
  end
  return module
end

local DexUI = { active=nil, action=nil, entry=nil }

function GoldCompat.isGen2Game(game)
  if not game then return GoldCompat.generation=="gen2" end
  local data=game.data
  return GoldCompat.generation=="gen2"
      or (data and (data.gen2MenuGfx or data.gen2Icons or data.gen2Sprites
          or data.gen2Pokedex))
      or game.generation==2
      or tostring(game.version or ""):lower()=="gold"
end

function GoldCompat.isGen2BattleState(state)
  return state and state.battle and state.game
      and type(state.shownHp)=="table"
      and type(state.shownMon)=="table"
end

function GoldCompat.sourceBattleState(battle)
  return battle and (battle.__gen3Source or battle) or nil
end

function GoldCompat.goldBattlePhase(state)
  local phase=state and state.phase or nil
  if phase=="moves" or phase=="choose-forget" then return "moveSelect" end
  if phase=="menu" then return "menu" end
  if phase=="done" or phase=="submenu" then return phase end
  -- Gold carries intro, resolving, level/move-learning questions, switch
  -- questions and refusal lines through one message surface.
  return "messages"
end

function GoldCompat.goldStatus(mon)
  if not mon then return nil end
  if (mon.hp or 0)<=0 then return "FNT" end
  local s=tostring(mon.status or ""):lower()
  if s=="" or s=="nil" then return nil end
  if s=="poison" or s=="toxic" or s=="psn" then return "PSN" end
  if s=="burn" or s=="brn" then return "BRN" end
  if s=="freeze" or s=="frz" then return "FRZ" end
  if s=="paralyze" or s=="paralysis" or s=="par" then return "PAR" end
  if s=="sleep" or s=="slp" then return "SLP" end
  return tostring(mon.status):upper()
end

function GoldCompat.presentBattleState(state)
  if not GoldCompat.isGen2BattleState(state) then return state end
  local core=state.battle or {}
  local data=state.game and state.game.data or {}
  local shown=state.shownMon or {}
  local shownHp=state.shownHp or {}

  local function side(name)
    local live=core[name]
    local mon=shown[name] or live
    if not mon then return nil end

    local gender=(mon and mon.gender) or (live and live.gender)
    if gender~="male" and gender~="female" then
      local source=live or mon
      local def=source and source.species and data.pokemon
        and data.pokemon[source.species]
      if def and source and source.dvs then
        local Mon=GoldCompat.engineModule("src.battle.gen2.Mon")
        if Mon and type(Mon.gender)=="function" then
          local ok,value=pcall(Mon.gender,def,source.dvs,{
            species=source.species, level=source.level,
          })
          if ok and (value=="male" or value=="female") then gender=value end
        end
      end
    end

    return {
      mon=mon,
      live=live,
      gender=gender,
      shownHP=shownHp[name] ~= nil and shownHp[name] or mon.hp,
      shownStatus=GoldCompat.goldStatus(mon),
      curMoves=mon.moves or {},
      disabledSlot=state.disabledSlot or state.disabledMoveSlot,
      fainted=(mon.hp or 0)<=0,
    }
  end

  local phase=GoldCompat.goldBattlePhase(state)
  local proxy={
    __gen2=true,
    __gen3Source=state,
    game=state.game,
    data=data,
    player=side("player"),
    enemy=side("enemy"),
    party=core.party,
    phase=phase,
    menuIndex=state.menuIndex or 1,
    moveIndex=(state.phase=="choose-forget" and state.forgetIndex)
        or state.moveIndex or 1,
    moveSwapIndex=state.moveSwapIndex,
    safari=state.contest or state.tutorial,
    demo=state.tutorial,
    frame=state.frame or 0,
    showEnemyTrainer=state.showEnemyTrainer,
    showPlayerBack=state.showPlayerTrainer,
    enemySendingOut=false,
    introBalls=false,
    introSlide=0,
    shownExp=state.shownExp or 0,
    shownLevel=state.shownLevel,
    message=state.message,
    messageTimer=state.messageTimer or 0,
    messagePages=state.messagePages,
    current=state.message and {
      text=state.message,
      done=(state.messageTimer or 0)<=0,
    } or nil,
    shown={},
    msgWaiting=(state.message and (state.messageTimer or 0)<=0) or false,
    msgPrompt=(state.phase=="ask-nickname" or state.phase=="ask-forget"
        or state.phase=="stop-learning" or state.phase=="ask-shift"),
  }
  return proxy
end

function GoldCompat.openGoldUISettings(game)
  if not (game and game.stack) then return end
  local okChrome,Chrome=pcall(require,"src.ui.gen2.Chrome")
  if not (okChrome and Chrome) then return end

  local state={
    game=game,
    isOpaque=false,
    index=1,
    scroll=0,
    rows=DexUI.uiRows,
    __gen3uiGoldOverlayKind="ui-settings",
  }

  function state:update()
    local input=self.game and self.game.input
    if not input then return end
    local count=#self.rows
    if input:wasPressed("up") then
      self.index=self.index>1 and self.index-1 or count
    elseif input:wasPressed("down") then
      self.index=self.index<count and self.index+1 or 1
    elseif input:wasPressed("a") then
      DexUI.activateUIRow(self.game,self.rows[self.index])
    elseif input:wasPressed("b") or input:wasPressed("start") then
      self.game.stack:pop()
      return
    end
    local visible=7
    if self.index<=self.scroll then self.scroll=self.index-1 end
    if self.index>self.scroll+visible then self.scroll=self.index-visible end
    self.scroll=math.max(0,math.min(self.scroll,math.max(0,count-visible)))
  end

  function state:draw()
    -- Suppress native Gen 2 Chrome. This state renders through widescreen using
    -- the same cream/dark/blue language as Gold OPTIONS.
    return
  end

  function state:drawsWidescreen() return false end
  function state:wantsFillScale() return false end
  function state:drawWidescreen() return end

  game.stack:push(state)
end
local spritePortraitResolver = (function()
  -- One self-contained resolver scope. Keeping these locals inside this
  -- anonymous function avoids Lua's 200-local limit for the main mod chunk.
  local PokemonSprites_ = require("src.pokemon.Sprites")
  local Assets_ = require("src.render.Assets")
  local PaletteFX_ = require("src.render.PaletteFX")

  local R = {
    mod = nil,
    cache = {},
    bounds = {},
    ba = nil,
    baV = nil,
    baAnimated = nil,
    baInterface = nil,
    baSets = {},
    lastFailCode = nil,
    lastFailReason = nil,
    modsLoaded = false,
    baUnavailable = false,
  }

  local function settingValue(setting)
    if setting and type(setting.get) == "function" then
      local ok, value = pcall(setting.get, setting)
      if ok then return value end
    end
    return nil
  end

  -- One-line-per-outcome connection diagnostic. Every previous round of this
  -- resolver either worked or silently returned nil on every pcall failure,
  -- which made "still not showing" impossible to root-cause without guessing.
  -- This never changes what renders -- it only makes the actual failure point
  -- observable in the mod log the next time menu portraits don't match battle.
  --
  -- IMPORTANT: these are separate throttle flags, not one shared boolean.
  -- A shared flag meant whichever outcome happened to fire FIRST (often "not
  -- found yet" during mod load, before Battle Art has finished its own init)
  -- permanently blocked every later message -- including the "connected"
  -- success line once Battle Art actually finished loading a moment later.
  -- That alone could fully explain a report of "zero diagnostic output" even
  -- though a real message did fire once, earlier than anyone was looking.
  local loggedNoHandle,loggedBadLib,loggedBadModule,loggedConnected=false,false,false,false
  local everFoundHandle=false
  local function diag(msg)
    if R.mod and R.mod.log and R.mod.log.info then
      pcall(R.mod.log.info,R.mod.log,"Gen 3 UI [Battle Art diag]: "..tostring(msg))
    end
  end

  -- R.lastFailReason/R.lastFailCode always reflect the MOST RECENT outcome
  -- (unlike the throttled log lines above, which only ever fire once each).
  -- The on-screen debug badge below reads these every draw, so it stays
  -- accurate even for a mod log the user never opens.
  local function setFail(code,msg)
    R.lastFailCode=code
    R.lastFailReason=msg
  end

  local function connectBattleArts()
    if R.ba and R.baV then return R.ba, R.baV end
    -- Before mods.loaded we keep retrying so load order can settle. Once the
    -- loader has declared the mod set complete, a missing Battle Art handle is
    -- stable until the next mods.loaded event and should not trigger two
    -- mod.find probes for every portrait on every frame.
    if R.baUnavailable then return nil end
    local mod = R.mod
    if not (mod and mod.find) then
      setFail("NOMODAPI","R.mod/mod.find unavailable -- resolver was never installed with a valid mod handle")
      return nil
    end

    local handle
    for _,id in ipairs({"BATTLE_ART_VOXEL_GEN2","BATTLE_ART_VOXEL_FORK"}) do
      local okHandle, candidate = pcall(mod.find, id)
      if okHandle and candidate and type(candidate.exports)=="table" then
        handle=candidate
        break
      end
    end
    if not handle then
      if R.modsLoaded then R.baUnavailable=true end
      setFail("NF","Battle Art not found via mod.find (BATTLE_ART_VOXEL_GEN2/"
        .."BATTLE_ART_VOXEL_FORK) -- not loaded, or not registered/ready yet")
      if not loggedNoHandle then
        loggedNoHandle=true
        diag(R.lastFailReason)
      end
      return nil
    end
    everFoundHandle=true
    R.baUnavailable=false

    local V = handle.exports.lib
    if type(V) ~= "table" or type(V.require) ~= "function" then
      setFail("LIB","found the mod but exports.lib is missing/malformed -- cannot reach its internals")
      if not loggedBadLib then
        loggedBadLib=true
        diag(R.lastFailReason)
      end
      return nil
    end

    local BA=handle.exports.battleArt
    local okBA=true
    if type(BA)~="table" then okBA,BA=pcall(V.require,"BattleArt") end
    if not (okBA and type(BA) == "table") then
      setFail("MOD","could not obtain its BattleArt module ("..tostring(BA)..")")
      if not loggedBadModule then
        loggedBadModule=true
        diag(R.lastFailReason)
      end
      return nil
    end

    local okAnimated,Animated=pcall(V.require,"AnimatedBattleArt")
    local okInterface,Interface=pcall(V.require,"InterfaceSprites")

    R.ba, R.baV = BA, V
    R.baAnimated = okAnimated and type(Animated)=="table" and Animated or nil
    R.baInterface = okInterface and type(Interface)=="table" and Interface or nil

    if not loggedConnected then
      loggedConnected=true
      local okArtMode,artMode=pcall(function() return BA.setting:get() end)
      local okIfaceMode,ifaceMode=pcall(function()
        return R.baInterface and R.baInterface.setting:get() or "(module unavailable)"
      end)
      diag(("connected. AnimatedBattleArt=%s InterfaceSprites=%s BATTLE ART setting=%s INTERFACE SPRITES setting=%s"):format(
        tostring(R.baAnimated~=nil), tostring(R.baInterface~=nil),
        tostring(okArtMode and artMode or ("<error: "..tostring(artMode)..">")),
        tostring(okIfaceMode and ifaceMode or ("<error: "..tostring(ifaceMode)..">"))))
    end
    return BA, V
  end

  -- Whether an on-screen debug badge should even be considered: only once we
  -- know some Battle-Art-shaped mod is actually present this session. Never
  -- shown to a user who simply doesn't have such a mod installed.
  --
  -- Checks fresh via mod.find rather than relying solely on everFoundHandle/
  -- R.ba (which only ever get set if connectBattleArts() was actually
  -- reached and ran) -- with the precedence flip in R.resolve() this should
  -- no longer matter, but this keeps the badge honest even if some other
  -- future code path skips battleArtsPortrait entirely.
  function R.debugRelevant()
    if everFoundHandle or R.ba~=nil then return true end
    if R.baUnavailable then return false end
    local mod=R.mod
    if not (mod and mod.find) then return false end
    for _,id in ipairs({"BATTLE_ART_VOXEL_GEN2","BATTLE_ART_VOXEL_FORK"}) do
      local ok,handle=pcall(mod.find,id)
      if ok and handle then return true end
    end
    return false
  end

  -- Short badge code for the CURRENT/most recent failure, or nil when either
  -- no Battle-Art-shaped mod is present, or the last attempt didn't fail.
  function R.debugBadge()
    if not R.debugRelevant() then return nil end
    return R.lastFailCode
  end

  local function visibleBounds(imageData,ignoreWhite)
    if not (imageData and type(imageData.getDimensions)=="function"
        and type(imageData.getPixel)=="function") then return nil end
    local w,h=imageData:getDimensions()
    local x0,y0,x1,y1=w,h,-1,-1
    local ok=pcall(function()
      for y=0,h-1 do
        for x=0,w-1 do
          local r,g,b,a=imageData:getPixel(x,y)
          local white=(tonumber(r) or 0)>0.985 and (tonumber(g) or 0)>0.985
            and (tonumber(b) or 0)>0.985
          local visible=(tonumber(a) or 0)>0.02 and not (ignoreWhite and white)
          if visible then
            if x<x0 then x0=x end; if x>x1 then x1=x end
            if y<y0 then y0=y end; if y>y1 then y1=y end
          end
        end
      end
    end)
    if not ok or x1<x0 or y1<y0 then return nil end
    return {x0=x0,x1=x1,y0=y0,y1=y1}
  end

  local function animatedFrame(frames,durations)
    if not (type(frames)=="table" and frames[1]) then return nil end
    if #frames==1 then return frames[1] end
    local total=0
    for i=1,#frames do total=total+math.max(1,tonumber(durations and durations[i]) or 100) end
    local seconds=love.timer and love.timer.getTime and love.timer.getTime() or 0
    local cursor=(seconds*1000)%math.max(1,total)
    for i=1,#frames do
      cursor=cursor-math.max(1,tonumber(durations and durations[i]) or 100)
      if cursor<0 then return frames[i] end
    end
    return frames[#frames]
  end

  local function battleArtsSet(V, generation)
    local cached = R.baSets[generation]
    if cached ~= nil then return cached or nil end
    if type(V.data) ~= "function" then
      R.baSets[generation] = false
      return nil
    end
    local ok, data = pcall(V.data, "animated_battle_sprites_" .. generation)
    R.baSets[generation] = (ok and data) or false
    return ok and data or nil
  end

  local function prepareBattleArtsFrame(BA, data)
    if type(BA.prepareData) == "function" then
      local displayMode = "default"
      if type(BA.displayMode) == "function" then
        local okMode, mode = pcall(BA.displayMode)
        if okMode and mode then displayMode = mode end
      end
      local ok, image = pcall(BA.prepareData, data, displayMode)
      if ok and image then return image end
    end

    local ok, image = pcall(love.graphics.newImage, data)
    if ok and image and image.setFilter then image:setFilter("nearest","nearest") end
    return ok and image or nil
  end

  local function battleArtsImageData(V, relative)
    local owner = V and V.mod
    if not (owner and type(owner.read) == "function") then return nil end

    local okRead, bytes = pcall(owner.read, owner, relative)
    if not (okRead and type(bytes) == "string" and #bytes > 0) then return nil end

    local okData, data = pcall(function()
      local fd = love.filesystem.newFileData(bytes, relative)
      return love.image.newImageData(fd)
    end)
    return okData and data or nil
  end

  local function battleArtsAnimatedFrame(BA, V, species, generation)
    local set = battleArtsSet(V, generation)
    local def = set and set[tostring(species or ""):upper()]
    def = def and def.front
    if not (def and def.image) then return nil end

    local key = "ba:read:" .. tostring(generation) .. ":" .. tostring(species)
    local cached = R.cache[key]
    if cached ~= nil then
      return cached or nil
    end

    local image
    local ok = pcall(function()
      -- Read the PNG through Battle Arts' own exported mod API object.
      -- Loader:_api binds mod:read() to that mod's path, so no cross-mod VFS
      -- path probing or filesystem getInfo call is involved.
      local sheet = battleArtsImageData(V, def.image)
      if not sheet then return end

      local sw, sh = sheet:getDimensions()
      local x, y, width, height
      local cells = def.cells
      local autoColumns = tonumber(def.autoColumns)

      if cells and cells[1] then
        local c = cells[1]
        x, y = tonumber(c.x) or 0, tonumber(c.y) or 0
        width, height = tonumber(c.width), tonumber(c.height)
      elseif autoColumns then
        if autoColumns < 1 or autoColumns % 1 ~= 0 or sw % autoColumns ~= 0 then return end
        x, y = 0, 0
        width, height = sw / autoColumns, sh
      else
        x, y = 0, 0
        width, height = tonumber(def.width), tonumber(def.height)
      end

      if not (width and height and width >= 1 and height >= 1) then return end
      x, y = math.floor(x + 0.5), math.floor(y + 0.5)
      width, height = math.floor(width + 0.5), math.floor(height + 0.5)
      if x < 0 or y < 0 or x + width > sw or y + height > sh then return end

      local frame = love.image.newImageData(width, height)
      frame:paste(sheet, 0, 0, x, y, width, height)
      image = prepareBattleArtsFrame(BA, frame)
    end)

    R.cache[key] = (ok and image) or false
    return ok and image or nil
  end

  local function battleArtsPortrait(mon,providerSource)
    local BA, V = connectBattleArts()
    if not (BA and V and mon and mon.species) then return nil end
    -- A successful connection this call clears any stale failure left over
    -- from before Battle Art finished loading; every branch below re-sets it
    -- if this specific attempt doesn't produce art.
    setFail(nil,nil)

    -- Battle Arts 2.0.9 explicitly separates interface ownership from battle
    -- ownership. OFF and MODDED mean the normal pokemon.sprite chain owns every
    -- menu portrait, so never force Battle Art art over the selected provider.
    local interfaceMode=settingValue(R.baInterface and R.baInterface.setting)
    if interfaceMode and interfaceMode~="battle_art" then
      setFail("IFACE","INTERFACE SPRITES is set to "..tostring(interfaceMode)
        ..", not BATTLE ART -- deferring to the active sprite provider/ROM by design")
      return nil
    end

    local mode = settingValue(BA.setting)
    if mode == "rom" then
      setFail("ROM","BATTLE ART setting is ROM -- deferring to native art by design")
      return nil
    end

    local species = mon.species
    if type(BA.speciesFor)=="function" then
      local okSpecies,resolved=pcall(BA.speciesFor,mon)
      if okSpecies and resolved then species=resolved end
    elseif type(BA.speciesAlias)=="function" then
      local okSpecies,resolved=pcall(BA.speciesAlias,species)
      if okSpecies and resolved then species=resolved end
    end

    local displayMode="default"
    if type(BA.displayMode)=="function" then
      local okDisplay,value=pcall(BA.displayMode)
      if okDisplay and value then displayMode=value end
    end
    -- Throttled per-species diagnostic: logs the FIRST time a given
    -- species/mode combination fails to produce interface art, so the exact
    -- failure (a thrown error vs. a clean "no frames for this species/gen")
    -- is visible instead of silently falling back to the ROM sprite.
    R.diagFail = R.diagFail or {}
    local function diagFailOnce(key,msg)
      R.diagFail = R.diagFail or {}
      if R.diagFail[key] then return end
      R.diagFail[key]=true
      diag(msg)
    end

    if mode=="static" and type(BA.interfaceStaticFrontImage)=="function" then
      local okImage,image=pcall(BA.interfaceStaticFrontImage,species,displayMode)
      if okImage and image then return image end
      local msg=("STATIC interfaceStaticFrontImage(%s) -> %s"):format(
          tostring(species), okImage and "no image (missing asset?)"
            or ("error: "..tostring(image)))
      setFail(okImage and "NOIMG" or "ERR",msg)
      diagFailOnce("static:"..tostring(species),msg)
    elseif mode=="animated" and R.baAnimated
        and type(R.baAnimated.interfaceFront)=="function" then
      local generation=settingValue(BA.frontAnimationSetting)
      local okFrames,frames,durations=pcall(R.baAnimated.interfaceFront,
        species,generation,displayMode,providerSource)
      if okFrames then
        local image=animatedFrame(frames,durations)
        if image then return image end
        local msg=("ANIMATED interfaceFront(%s,%s) returned no usable frame (frames=%s)"):format(
            tostring(species),tostring(generation),tostring(frames))
        setFail("NOFRAME",msg)
        diagFailOnce("anim:"..tostring(species)..":"..tostring(generation),msg)
      else
        local msg=("ANIMATED interfaceFront(%s,%s) errored: %s"):format(
            tostring(species),tostring(generation),tostring(frames))
        setFail("ERR",msg)
        diagFailOnce("anim:"..tostring(species)..":"..tostring(generation),msg)
      end
    elseif mode=="animated" and not (R.baAnimated
        and type(R.baAnimated.interfaceFront)=="function") then
      local msg="ANIMATED mode selected but AnimatedBattleArt.interfaceFront is unavailable "
        .."(R.baAnimated="..tostring(R.baAnimated~=nil)..")"
      setFail("NOANIM",msg)
      diagFailOnce("anim-module-missing",msg)
    end

    local function slug(value)
      local name = tostring(value or ""):lower()
      name = name:gsub("♀", "-f"):gsub("♂", "-m")
      name = name:gsub("['’%.]", "")
      name = name:gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "")
      return name
    end
    local name = slug(species)

    local function preparedRelative(relative)
      local key = "ba:file:" .. relative
      local cached = R.cache[key]
      if cached ~= nil then return cached or nil end
      local data = battleArtsImageData(V, relative)
      local image = data and prepareBattleArtsFrame(BA, data) or nil
      R.cache[key] = image or false
      return image
    end

    local generation = settingValue(BA.frontAnimationSetting)

    -- DUPLICATE FIX: MODDED leaves all species art to the external provider.
    if type(BA.prefersModded) == "function" then
      local okModded, modded = pcall(BA.prefersModded)
      if okModded and modded then return nil end
    end

    -- Fallback tail: the bespoke API above already tried and, if it failed,
    -- already logged/set the reason via setFail/diagFailOnce -- this only
    -- overwrites that reason if this second attempt also comes up empty, so
    -- the on-screen badge always reflects why NOTHING worked, not just the
    -- first attempt.
    if mode == "static" then
      local image=preparedRelative("assets/battle/front-static/" .. name .. ".png")
      if image then return image end
      local msg="raw STATIC asset front-static/"..name..".png not found either"
      setFail("NOIMG",msg)
      diagFailOnce("static-raw:"..tostring(species),msg)
      return nil
    end

    if mode ~= "animated" then
      setFail("MODE","unrecognized BATTLE ART setting value "..tostring(mode))
      return nil
    end
    if not tostring(generation or ""):match("^gen[1-5]$") then
      setFail("GEN","unrecognized front animation generation "..tostring(generation))
      return nil
    end

    if generation == "gen1" then
      local image=preparedRelative(
        "assets/battle/front-animated/gen1/" .. name .. ".png")
      if image then return image end
      local msg="raw gen1 asset front-animated/gen1/"..name..".png not found either"
      setFail("NOIMG",msg)
      diagFailOnce("gen1-raw:"..tostring(species),msg)
      return nil
    end

    local image=battleArtsAnimatedFrame(BA, V, species, generation)
    if image then return image end
    local msg=("raw animated-atlas decode for %s/%s also produced no frame"):format(
      tostring(species),tostring(generation))
    setFail("NOFRAME",msg)
    diagFailOnce("atlas-raw:"..tostring(species)..":"..tostring(generation),msg)
    return nil
  end

  local function enginePalette(data, species, mon)
    -- Gold's normal front sprites are grayscale source art plus the species'
    -- native two-color battle palette. Use the same Gen 2 palette resolver
    -- the battle renderer uses, instead of the Gen 1/SGB mon palette helper.
    if GoldCompat.generation=="gen2" then
      local Palettes=GoldCompat.engineModule("src.world.gen2.Palettes")
      -- IMPORTANT: Gold's Pokémon battle palettes live in game.data.gen2Palettes.
      -- This is the exact table src/ui/gen2/BattleState.lua stores as
      -- self.palettes before calling Palettes.monColors().
      local paletteData=data and data.gen2Palettes
      local colors=Palettes and type(Palettes.monColors)=="function"
        and Palettes.monColors(paletteData,species,mon and mon.shiny)
        or nil
      if colors then
        return "gen2-native-pal:"..tostring(species)..":"..tostring(mon and mon.shiny),colors
      end
    end

    local colors = PaletteFX_.monPal(data, species)
    if not colors then return "none", nil end
    local name = PaletteFX_.monPalName(data, species) or "MON"
    if PaletteFX_.usesGbcPack() then name = "redpp:" .. name end
    return name, colors
  end

  local function enginePortrait(game, mon, kind)
    local data = game and game.data
    local def = data and data.pokemon and data.pokemon[mon.species]
    local vanillaPath = def and def.spriteFront
    local path, trueColor = PokemonSprites_.path(
      data, mon.species, "front", { mon=mon, kind=kind or "battle" })
    if not path then return nil end

    -- If another sprite package replaces the live front path, display that
    -- authored image as-is instead of forcing Gold's native 4-shade palette
    -- back over it. Vanilla paths keep their normal Gold palette behavior.
    local providerSelected=vanillaPath and path~=vanillaPath or false
    if providerSelected then
      trueColor = true
    end

    local palName, colors = enginePalette(data, mon.species, mon)
    local key = "engine:" .. path .. ":" .. (trueColor and "truecolor" or palName)
    local cached = R.cache[key]
    if cached ~= nil then
      return cached or nil, R.bounds[key],providerSelected,path
    end

    local image,imageData
    if trueColor or not colors or not (love.image and love.image.newImageData) then
      imageData=Assets_.imageData(path)
      image = Assets_.image(path)
    else
      imageData = Assets_.imageData(path)
      if imageData then
        imageData:mapPixel(function(_,_,r,g,b,a)
          if a == 0 then return r,g,b,a end
          local col = r > 0.83 and colors[1]
            or r > 0.5 and colors[2]
            or r > 0.17 and colors[3]
            or colors[4]
          return col[1]/255, col[2]/255, col[3]/255, a
        end)
        image = love.graphics.newImage(imageData)
      end
    end

    if image and image.setFilter then image:setFilter("nearest","nearest") end
    R.cache[key] = image or false
    local meta=visibleBounds(imageData,not trueColor) or {}
    meta.trueColor=trueColor and true or false
    R.bounds[key]=meta
    return image,meta,providerSelected,path
  end

  function R.invalidate()
    -- Sprite settings and provider order are live. Never pin a prior provider's
    -- decoded image after Battle Art or another sprite mod changes selection.
    R.cache={}
    R.bounds={}
  end

  function R.install(mod)
    R.mod = mod
    connectBattleArts()
    if mod.events and type(mod.events.on)=="function" then
      mod.events:on("mod.options_changed",function() R.invalidate() end)
      mod.events:on("mods.loaded",function()
        R.modsLoaded=true
        R.baUnavailable=false
        R.invalidate()
        connectBattleArts()
      end,-20000)
    end
    return true
  end

  local function battleArtsResult(mon,providerPath)
    local image = battleArtsPortrait(mon,providerPath)
    if not image then return nil end
    -- Battle Arts already records the alpha-visible bounds for every image
    -- prepared through BattleArt.prepareData(). Pass those bounds to the UI
    -- so portrait sizing is based on the Pokemon itself instead of the
    -- surrounding transparent canvas. This is especially important for the
    -- Gen 4 collection, where authored canvas occupancy varies by species.
    local meta
    local BA=R.ba
    if BA and type(BA.metrics) == "function" then
      local okMetrics, metrics = pcall(BA.metrics, image)
      if okMetrics and type(metrics) == "table"
          and metrics.x0 and metrics.x1 and metrics.y0 and metrics.y1 then
        meta = {
          x0 = metrics.x0, x1 = metrics.x1,
          y0 = metrics.y0, y1 = metrics.y1,
        }
      end
    end
    meta = meta or {}
    -- Battle Arts PNGs are authored color assets. Always mark the exact
    -- resolved image true-color so the global palette pass cannot turn
    -- Party/PC/Pokédex portraits back into grayscale.
    meta.trueColor = true
    return image, meta
  end

  function R.resolve(game, mon, kind)
    if not (game and game.data and mon and mon.species) then return nil end

    local providerImage,providerMeta,providerSelected,providerPath=
      enginePortrait(game,mon,kind)

    -- PRECEDENCE FLIP (was: engine provider first, Battle Art only as
    -- fallback when the provider stayed vanilla). That order silently
    -- starved Battle Art of every call whenever enginePortrait's own
    -- resolved path happened to differ from the raw vanilla battle-front
    -- path string for a non-"battle" kind -- which it can, for reasons
    -- having nothing to do with any real custom provider being active, and
    -- which would explain zero Battle Art connection attempts ever firing
    -- despite the badge/logging added specifically to catch that. Battle
    -- Art's own generic pokemon.sprite hook (lib/InterfaceSprites.lua's
    -- ourFront()) is confirmed from its real source to return nil for every
    -- interface kind under its own default settings and rely entirely on
    -- this bespoke API -- so asking Battle Art first here can never steal
    -- art away from a genuinely different custom sprite provider; the
    -- generic engine path stays queryable as an unconditional fallback.
    local baImage,baMeta = battleArtsResult(mon,providerPath)
    if baImage then return baImage,baMeta end

    if providerSelected and providerImage then
      return providerImage,providerMeta
    end

    return providerImage,providerImage and providerMeta or nil
  end

  return R
end)()

local function clearBattleUIState()
  State.activeBattle=nil
  State.activeBattleMoveLearn=nil
  State.activeBattleMoveParty=nil
end

local function clearPokemonUIState()
  State.activeParty=nil
  State.activeTMParty=nil
  State.activeItemTargetParty=nil
  State.activeMoveLearn=nil
  State.activeTMPromptFlow=nil
end

local function clearOverworldMenuState()
  State.activeStartMenu=nil
  State.activeBagMenu=nil
  State.activeBagActionMenu=nil
end

local function clearPCUIState()
  State.activePCAccessMenu=nil
  State.activePCMenu=nil
  State.activePCList=nil
  State.activePCActionMenu=nil
end

local function clearShopUIState()
  State.activeShopMenu=nil
  State.activeShopList=nil
  State.activeShopQuantity=nil
end


local UI_TEXT_SCALE = 1.08

local GOLD_SCREEN_TOGGLE_SPECS = {
  {key="revampedTrainerCardUI", label="TRAINER CARD UI"},
  {key="revampedSaveUI",        label="SAVE SCREEN UI"},
  {key="revampedOptionsUI",     label="OPTIONS SCREEN UI"},
  {key="revampedModsUI",        label="MOD MANAGER UI"},
  {key="revampedPokegearUI",    label="POKéGEAR UI"},
  {key="revampedLevelUpUI",     label="LEVEL-UP STATS UI"},
}

local OPTION_DEFAULTS = {
  revampedBattleUI = true,
  revampedPokemonMenu = true,
  revampedOverworldMenus = true,
  revampedPokeMartUI = true,
  revampedPokemonPC = true,
  revampedPokedex = true,
  revampedDialogueBoxes = true,
  hideNativeBattleUI = false,
  mobileBattleUI = false,
  iosTopBattleHUD = false,
  uiTextSize = "normal",
  uiTextWeight = "normal",
  uiBoxScale = "normal",
  uiBorderColor = "gold",
  uiBorderStyle = "classic",
  battleMoveLayout = "list",
}
for _,spec in ipairs(GOLD_SCREEN_TOGGLE_SPECS) do
  OPTION_DEFAULTS[spec.key]=true
end

GoldCompat.optionCache={}
GoldCompat.derivedOptionCache={}
GoldCompat.nilOptionValue={}

function GoldCompat.invalidateOptionCache(key)
  if key~=nil then
    GoldCompat.optionCache[key]=nil
  else
    GoldCompat.optionCache={}
  end
  -- Derived typography/layout values are tiny but extremely hot: every text
  -- label asks for at least one of them. Clear them together on any UI option
  -- change instead of recomputing strings/branches dozens of times per frame.
  GoldCompat.derivedOptionCache={}
end

function GoldCompat.cacheOptionValue(key,value)
  if key==nil then return end
  GoldCompat.optionCache[key]=(value==nil) and GoldCompat.nilOptionValue or value
  GoldCompat.derivedOptionCache={}
end

local function optionValue(key)
  local cached=GoldCompat.optionCache[key]
  if cached~=nil then
    return cached==GoldCompat.nilOptionValue and nil or cached
  end

  local value=nil
  if modRef and modRef.options and modRef.options.get then
    local ok,resolved=pcall(modRef.options.get,modRef.options,key)
    if ok then value=resolved end
  end
  if value==nil then value=OPTION_DEFAULTS[key] end

  GoldCompat.optionCache[key]=(value==nil)
      and GoldCompat.nilOptionValue or value
  return value
end

local function featureEnabled(key)
  return optionValue(key) ~= false
end

-- HIDE NATIVE BATTLE UI is a master presentation-safety switch, not merely
-- another cosmetic toggle. If it is on, our battle presentation remains
-- available even if the regular BATTLE UI toggle is off; otherwise strict
-- native suppression could leave the player with no usable command/HUD layer.
local function battleUiPresentationEnabled()
  return featureEnabled("revampedBattleUI")
      or featureEnabled("hideNativeBattleUI")
end

function GoldCompat.userTextScale()
  local cached=GoldCompat.derivedOptionCache.textScale
  if cached~=nil then return cached end
  local v=tostring(optionValue("uiTextSize") or "normal")
  local value=1.00
  if v=="small" then value=0.90
  elseif v=="large" then value=1.12
  elseif v=="x-large" then value=1.24 end
  GoldCompat.derivedOptionCache.textScale=value
  return value
end

function GoldCompat.userTextWeight()
  local cached=GoldCompat.derivedOptionCache.textWeight
  if cached~=nil then return cached end
  local v=tostring(optionValue("uiTextWeight") or "normal")
  local value=0.45
  if v=="thin" then value=0.00
  elseif v=="bold" then value=0.90 end
  GoldCompat.derivedOptionCache.textWeight=value
  return value
end

function GoldCompat.userBoxScale()
  local cached=GoldCompat.derivedOptionCache.boxScale
  if cached~=nil then return cached end
  local v=tostring(optionValue("uiBoxScale") or "normal")
  local value=1.00
  if v=="compact" then value=0.86
  elseif v=="large" then value=1.08
  elseif v=="x-large" then value=1.14 end
  GoldCompat.derivedOptionCache.boxScale=value
  return value
end

-- Pokédex CONTENTS list (DexUI.draw's right-hand panel) row height/visible
-- count, same "single source of truth, shrink the row count rather than
-- the text" approach as GoldCompat.bagPackVisibleRows below -- General
-- Sweep, v2.1.28. The row's own name label draws at 2.8 (the largest text
-- in the row); DexUI.drawAction (the action-card flyout next to the
-- selected row) must use the SAME row height/visible count or its flyout
-- position drifts away from the row it's supposed to sit beside, so both
-- call these instead of each keeping their own copy of "8"/"11".
function GoldCompat.dexListRowHeight()
  return GoldCompat.dynamicRowHeight(2.8,9,3)
end

function GoldCompat.dexListVisibleRows()
  local rowH=GoldCompat.dexListRowHeight()
  local listTop,listBottom=31,127
  local maxFitRows=math.max(1,math.floor((listBottom-listTop)/rowH))
  return math.min(8,maxFitRows)
end

function GoldCompat.bagPackVisibleRows(embedded)
  -- Single source of truth for how many Bag/Pack list rows fit above the
  -- description strip, shared by GoldCompat.drawGoldPack (draw-time row
  -- count) and the Gen 1 view-scroll tracker (gen1BagRefresh/gen1BagMoveView)
  -- so input scrolling and what is actually drawn never disagree. At the
  -- default text size the list and the description strip were flush with no
  -- margin, so any larger glyph metrics (bigger TEXT SIZE / bold TEXT
  -- THICKNESS) pushed the last row's selection highlight and label into the
  -- strip's border. Reserve a clearance gap that grows with the user's text
  -- scale and show fewer rows (still scrollable) instead.
  local h=embedded and 112 or 120
  local rowH=GoldCompat.bagPackRowHeight()
  local listTop=23
  local listGap=2
  local listBottom=(h-29)-listGap
  local maxFitRows=math.max(1,math.floor((listBottom-listTop)/rowH))
  return math.min(embedded and 6 or 7,maxFitRows)
end

-- Same reasoning as GoldCompat.bagPackVisibleRows above, sized for the
-- Mart's own (smaller) list panel instead of the Bag/Pack's: the Gen 1
-- categorized SELL body reserves an 18-unit header (pocket tabs + rule)
-- inside the shared 78-tall Mart panel (drawShopPanel(6,25,148,78,...)),
-- and this is the single source of truth for how many rows fit below it,
-- shared by both the SELL input wrap (installPCIntegration's ListMenu.new)
-- and drawShopSellPocketBody, so scrolling and drawing never disagree.
function GoldCompat.shopSellVisibleRows()
  local rowH=GoldCompat.bagPackRowHeight()
  local listTop=18
  local listBottom=78-2
  local maxFitRows=math.max(1,math.floor((listBottom-listTop)/rowH))
  return math.min(5,maxFitRows)
end

function GoldCompat.dialogueLayoutScale()
  local textScale=GoldCompat.userTextScale()
  local boxScale=GoldCompat.userBoxScale()
  local textGrowth=math.max(0,textScale-1)

  -- Dialogue grows with large text instead of keeping a fixed shell and
  -- clipping. Compact remains meaningful, but never wins over readability.
  local heightScale=math.max(boxScale,1+textGrowth*1.85)
  local widthScale=math.max(1,boxScale)*(1+textGrowth*0.28)
  return widthScale,heightScale
end


DexUI.uiRows={
  {key="revampedBattleUI",label="BATTLE UI",kind="toggle"},
  {key="revampedPokemonMenu",label="POKéMON MENU",kind="toggle"},
  {key="revampedOverworldMenus",label="OVERWORLD MENUS",kind="toggle"},
  {key="revampedPokeMartUI",label="POKéMART UI",kind="toggle"},
  {key="revampedPokemonPC",label="POKéMON PC",kind="toggle"},
  {key="revampedPokedex",label="POKéDEX",kind="toggle"},
  {key="revampedDialogueBoxes",label="DIALOGUE",kind="toggle"},
  {key="hideNativeBattleUI",label="HIDE NATIVE BATTLE UI",kind="toggle"},
  {key="mobileBattleUI",label="MOBILE BATTLE UI",kind="toggle"},
  {key="iosTopBattleHUD",label="IOS TOP BATTLE HUD",kind="toggle"},
  {key="uiTextSize",label="TEXT SIZE",kind="choice",
    values={"small","normal","large","x-large"}},
  {key="uiTextWeight",label="TEXT THICKNESS",kind="choice",
    values={"thin","normal","bold"}},
  {key="uiBoxScale",label="UI BOX SIZE",kind="choice",
    values={"compact","normal","large","x-large"}},
  {key="uiBorderColor",label="BORDER COLOR",kind="choice",
    values={"gold","red","orange","yellow","green","cyan","blue","purple",
      "pink","brown","gray","white","black"}},
  {key="uiBorderStyle",label="BORDER STYLE",kind="choice",
    values={"classic","rounded","sharp"}},
  {key="battleMoveLayout",label="MOVE MENU LAYOUT",kind="choice",
    values={"list","grid"}},
}
for _,spec in ipairs(GOLD_SCREEN_TOGGLE_SPECS) do
  table.insert(DexUI.uiRows,{
    key=spec.key,
    label=spec.label,
    kind="toggle",
  })
end

function DexUI.setOption(game,key,value)
  local loader=game and game.mods
  if not loader then return false end

  loader.modOptions=loader.modOptions or {}
  local bucket=loader.modOptions["gen3_battle_ui"]
  if not bucket then
    bucket={}
    loader.modOptions["gen3_battle_ui"]=bucket
  end
  bucket[key]=value
  -- Make the in-memory presentation respond immediately, even before the
  -- loader's options-changed event is delivered back to this mod.
  GoldCompat.cacheOptionValue(key,value)

  -- Persist through the same options file used by the mod manager. The public
  -- options facade is intentionally read-only at runtime, so this in-game UI
  -- uses the engine-owned SaveData serializer rather than inventing storage.
  local okSave=pcall(function()
    local SaveData=require("src.core.SaveData")
    local fs=loader.fs
    if not (fs and fs.write) then return end
    local opts=SaveData.loadOptions(fs)
    opts.modOptions=opts.modOptions or {}
    opts.modOptions["gen3_battle_ui"]=opts.modOptions["gen3_battle_ui"] or {}
    opts.modOptions["gen3_battle_ui"][key]=value
    SaveData.saveOptions(opts,fs)
  end)

  -- Match ManagerState's runtime notification contract when available.
  pcall(function()
    if loader.events and loader.events.emit then
      loader.events:emit("mod.options_changed",
        {mod="gen3_battle_ui",key=key,value=value})
    end
  end)

  return okSave or true
end

function DexUI.optionDisplay(row)
  local value=optionValue(row.key)
  if row.kind=="toggle" then
    return value~=false and "ON" or "OFF"
  end
  return tostring(value or ""):upper()
end

function DexUI.activateUIRow(game,row)
  if not row then return end
  if row.kind=="toggle" then
    DexUI.setOption(game,row.key,not featureEnabled(row.key))
    return
  end

  if row.kind=="choice" and row.values and #row.values>0 then
    local current=optionValue(row.key)
    local index=1
    for i,value in ipairs(row.values) do
      if value==current then index=i break end
    end
    index=index<#row.values and index+1 or 1
    DexUI.setOption(game,row.key,row.values[index])
  end
end


local function bagStateForMenu(game)
  if not (game and game.stack and game.stack.states) then return nil end
  for i=#game.stack.states,1,-1 do
    local state = game.stack.states[i]
    if state and state.__gen3uiBag then
      return state
    end
  end
  return nil
end


local function stateExistsInStack(game, target)
  if not (game and game.stack and game.stack.states and target) then return false end
  for _,state in ipairs(game.stack.states) do
    if state == target then return true end
  end
  return false
end

local function battleStateInStack(game)
  if not (game and game.stack and game.stack.states) then return nil end
  for i=#game.stack.states,1,-1 do
    local state=game.stack.states[i]
    if getmetatable(state)==BattleState
        or state==State.activeBattle
        or GoldCompat.isGen2BattleState(state) then
      return state
    end
  end
  return nil
end

-- The hard-hide option applies to every UI state reached from a live battle,
-- not only the core BattleState. This lets Party/Bag/Summary/MoveLearn and
-- TextBox/ChoiceBox stay custom while the same feature toggles remain fully
-- independent everywhere outside battle.
function GoldCompat.strictBattleUiForGame(game)
  return featureEnabled("hideNativeBattleUI")
      and battleStateInStack(game)~=nil
end

local function makeBattleMovePartyState(game,moveMenu)
  if not (game and moveMenu and moveMenu.mon) then return nil end

  local party=(game.save and game.save.party) or {}
  local selected=1
  for i,mon in ipairs(party) do
    if mon==moveMenu.mon then
      selected=i
      break
    end
  end

  local state={
    game=game,
    party=party,
    index=selected,
    selected=selected,
    blink=0,
    keepOpen=true,
    __gen3uiBattleMoveParty=true,
  }

  -- drawPartyFinal expects this method on a real PartyMenu.
  function state:bottomMessage()
    return "Choose a move to replace."
  end

  return state
end


local function shopMenuLabel(item)
  return tostring(item and item.label or ""):upper()
end

local function shopMainItems(items)
  if type(items)~="table" or #items~=3 then return false end
  return shopMenuLabel(items[1])=="BUY"
      and shopMenuLabel(items[2])=="SELL"
      and shopMenuLabel(items[3])=="QUIT"
end


local function shopStateInStack(game)
  if not (game and game.stack and game.stack.states) then return nil end
  for i=#game.stack.states,1,-1 do
    local state=game.stack.states[i]
    if state and (state.__gen3uiShopList or state.__gen3uiShopMain) then
      return state
    end
  end
  return nil
end

local function pcMenuLabel(item)
  return tostring(item and item.label or ""):upper()
end

local function pcAccessItems(items)
  if type(items)~="table" or #items<2 then return false end
  local hits=0
  for _,item in ipairs(items) do
    local label=pcMenuLabel(item)
    if label:find("PC",1,true) or label=="LOG OFF" then hits=hits+1 end
  end
  return hits>=2 and pcMenuLabel(items[#items])=="LOG OFF"
end

local function pcMainItems(items)
  if type(items)~="table" or #items<4 then return false end
  local labels={}
  for i,item in ipairs(items) do labels[i]=pcMenuLabel(item) end
  return labels[1]:find("WITHDRAW",1,true)
      and labels[2]:find("DEPOSIT",1,true)
      and labels[3]:find("RELEASE",1,true)
      and labels[4]:find("CHANGE BOX",1,true)
end

local function pcActionItems(items)
  if type(items)~="table" or #items<3 then return false end
  local a=pcMenuLabel(items[1])
  return (a=="WITHDRAW" or a=="DEPOSIT")
      and pcMenuLabel(items[2])=="STATS"
      and pcMenuLabel(items[3])=="CANCEL"
end

function GoldCompat.pcListTitle(title)
  local t=tostring(title or ""):upper()
  if t=="PARTY (DEPOSIT)" or t=="CHANGE BOX" then return true end
  if t:match("^BOX %d+ %(WITHDRAW%)$") then return true end
  if t:match("^BOX %d+ %(RELEASE%)$") then return true end
  return false
end

local function isPCOwnedState(state)
  return state and (
    state.__gen3uiPCAccess
    or state.__gen3uiPCMain
    or state.__gen3uiPCList
    or state.__gen3uiPCAction
  )
end

local function pcStateInStack(game)
  if not (game and game.stack and game.stack.states) then return nil end
  for i=#game.stack.states,1,-1 do
    local state=game.stack.states[i]
    if isPCOwnedState(state) then return state end
  end
  return nil
end

local function savePanelInStack(game)
  if not (game and game.stack and game.stack.states) then return nil end
  for i=#game.stack.states,1,-1 do
    local state=game.stack.states[i]
    if state and state.__gen3uiSavePanel then return state end
  end
  return nil
end


function GoldCompat.supportedOverworldMenuState(state)
  if not state then return false end

  -- These are the menu classes for which this mod has complete replacement
  -- renderers. Everything else fails safely to the native implementation.
  if state.__gen3uiStart then return true end
  if state.__gen3uiHangingOptions then return true end
  if state.__gen3uiHangingMods then return true end
  if state.__gen3uiHangingTrainer then return true end
  if getmetatable(state)==BagMenu then return true end
  if getmetatable(state)==PartyMenu then return true end
  if getmetatable(state)==MoveLearnMenu then return true end
  if state.__gen3uiPokedex then return true end
  if state.__gen3uiPokedexAction then return true end
  if state.__gen3uiDexEntry then return true end

  -- Bag item action menus are marked explicitly by our own hook.
  if state.__gen3uiBagAction or state.__gen3uiBag then return true end
  if isPCOwnedState(state) then return true end
  if state.__gen3uiShopMain or state.__gen3uiShopList
      or state.__gen3uiShopQuantity then return true end

  return false
end


local function canIntegrateMoveLearn(game, moveMenu)
  -- HARD HIDE is a battle-wide presentation guarantee.  A user may keep the
  -- ordinary POKéMON MENU toggle off outside battle, but once a move-learning
  -- state is stacked over a live battle we must still claim its presentation
  -- so the stock forget-move UI can never flash through.
  if not (featureEnabled("revampedPokemonMenu")
      or GoldCompat.strictBattleUiForGame(game)) then return false end
  if not (State.activeTMParty and moveMenu and moveMenu.mon) then return false end
  if not stateExistsInStack(game, State.activeTMParty) then return false end

  local party = State.activeTMParty.party or (game.save and game.save.party) or {}
  local selected = math.max(1, math.min(State.activeTMParty.index or 1, #party))
  return party[selected] == moveMenu.mon
end

local function installVerifiedOptions(mod)
  modRef = mod
  GoldCompat.invalidateOptionCache()

  -- This exact row format is consumed by ManagerState's options screen:
  -- type=toggle, key, label, default.
  local optionDefs={
    {
      key = "revampedBattleUI",
      type = "toggle",
      label = "BATTLE UI",
      default = true,
    },
    {
      key = "revampedPokemonMenu",
      type = "toggle",
      label = "POKéMON MENU",
      default = true,
    },
    {
      key = "revampedOverworldMenus",
      type = "toggle",
      label = "OVERWORLD MENUS",
      default = true,
    },
    {
      key = "revampedPokeMartUI",
      type = "toggle",
      label = "POKéMART UI",
      default = true,
    },
    {
      key = "revampedPokemonPC",
      type = "toggle",
      label = "POKéMON PC UI",
      default = true,
    },
    {
      key = "revampedPokedex",
      type = "toggle",
      label = "POKéDEX UI",
      default = true,
    },
    {
      key = "revampedDialogueBoxes",
      type = "toggle",
      label = "DIALOGUE / TEXT BOXES",
      default = true,
    },
    {
      key = "hideNativeBattleUI",
      type = "toggle",
      label = "HIDE OLD BATTLE UI",
      default = false,
    },
    {
      key = "mobileBattleUI",
      type = "toggle",
      label = "MOBILE BATTLE UI",
      default = false,
    },
    {
      key = "iosTopBattleHUD",
      type = "toggle",
      label = "IOS TOP BATTLE HUD",
      default = false,
    },
    {
      key = "battleMoveLayout",
      type = "choice",
      label = "MOVE MENU LAYOUT",
      default = "list",
      choices = {
        {"4X1 LIST", "list"},
        {"2X2 GRID", "grid"},
      },
    },
    {
      key = "uiTextSize",
      type = "choice",
      label = "TEXT SIZE",
      default = "normal",
      choices = {
        {"SMALL","small"},
        {"NORMAL","normal"},
        {"LARGE","large"},
        {"X-LARGE","x-large"},
      },
    },
    {
      key = "uiTextWeight",
      type = "choice",
      label = "TEXT THICKNESS",
      default = "normal",
      choices = {
        {"THIN","thin"},
        {"NORMAL","normal"},
        {"BOLD","bold"},
      },
    },
    {
      key = "uiBoxScale",
      type = "choice",
      label = "UI BOX SIZE",
      default = "normal",
      choices = {
        {"COMPACT","compact"},
        {"NORMAL","normal"},
        {"LARGE","large"},
        {"X-LARGE","x-large"},
      },
    },
    {
      key = "uiBorderColor",
      type = "choice",
      label = "BORDER COLOR",
      default = "gold",
      choices = {
        {"GOLD", "gold"},
        {"RED", "red"},
        {"ORANGE", "orange"},
        {"YELLOW", "yellow"},
        {"GREEN", "green"},
        {"CYAN", "cyan"},
        {"BLUE", "blue"},
        {"PURPLE", "purple"},
        {"PINK", "pink"},
        {"BROWN", "brown"},
        {"GRAY", "gray"},
        {"WHITE", "white"},
        {"BLACK", "black"},
      },
    },
    {
      key = "uiBorderStyle",
      type = "choice",
      label = "BORDER STYLE",
      default = "classic",
      choices = {
        {"CLASSIC", "classic"},
        {"DOUBLE", "double"},
        {"BOLD", "bold"},
        {"DASHED", "dashed"},
        {"DOTTED", "dotted"},
        {"STRIPED", "striped"},
        {"CHECKER", "checker"},
        {"MINIMAL", "minimal"},
      },
    },
  }
  for _,spec in ipairs(GOLD_SCREEN_TOGGLE_SPECS) do
    optionDefs[#optionDefs+1]={
      key=spec.key,
      type="toggle",
      label=spec.label,
      default=true,
    }
  end
  mod.options:define(optionDefs)
  GoldCompat.invalidateOptionCache()

  if mod.log then
    mod.log:info("Gen 3 Inspired UI Overhaul: verified Mod Manager options registered")
  end
end


local fonts = {}
local vanillaTextPatched = false
local overworldUIPatched = false
local overworldFonts = {}
local partyRenderOX, partyRenderOY, partyRenderScale = 0, 0, 1

-- -------------------------------------------------------------------------
-- Helpers
-- -------------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function shownHP(b)
  if not b then return 0 end
  return math.max(0, math.floor(b.shownHP or (b.mon and b.mon.hp) or 0))
end

local function maxHP(b)
  return math.max(1, math.floor(
    (b and b.mon and (b.mon.maxHp
      or (b.mon.stats and b.mon.stats.hp))) or 1
  ))
end

function GoldCompat.speciesDef(battle, battler)
  if not (battle and battle.data and battle.data.pokemon and battler
      and battler.mon and battler.mon.species) then return nil end
  return battle.data.pokemon[battler.mon.species]
end

local function expRatio(battle, battler)
  if battle and battle.__gen2 then
    -- Gold's BattleState deliberately chases a 64-pixel EXP value separately
    -- from the already-committed monster experience.
    return clamp((tonumber(battle.shownExp) or 0)/64,0,1)
  end

  local mon = battler and battler.mon
  local def = GoldCompat.speciesDef(battle, battler)
  if not (mon and def) then return 0 end

  local cap = (battle.data.constants and battle.data.constants.levelCap) or 100
  local level = math.max(1, math.floor(mon.level or 1))
  if level >= cap then return 1 end

  local rates = battle.data.growth_rates
  local cur = Growth.expForLevel(def.growthRate, level, rates)
  local nxt = Growth.expForLevel(def.growthRate, level + 1, rates)
  return clamp(((mon.exp or cur) - cur) / math.max(1, nxt - cur), 0, 1)
end

function GoldCompat.safeExpRatio(battle, battler)
  local ok, value = pcall(expRatio, battle, battler)
  if not ok or type(value) ~= "number" or value ~= value then
    return 0
  end
  return clamp(value, 0, 1)
end

local function battleInStack(game, battle)
  battle=GoldCompat.sourceBattleState(battle)
  if not (game and game.stack and game.stack.states and battle) then return false end
  for _, state in ipairs(game.stack.states) do
    if state == battle then return true end
  end
  return false
end

local function topState(game)
  if not (game and game.stack) then return nil end
  if game.stack.top then
    local ok,state=pcall(game.stack.top,game.stack)
    if ok and state then return state end
  end
  local states=game.stack.states
  return states and states[#states] or nil
end

function GoldCompat.namingScreenOwnsForeground(game)
  local top=topState(game)
  if not top then return false end

  -- Current Gen1Recomp NamingScreen uses this metatable. screenId keeps this
  -- safe for registered/mod-provided naming screens following Screens' contract.
  return getmetatable(top)==NamingScreen
      or top.screenId=="NamingScreen"
      or top.screenId=="naming"
end

local function battleOwnsForeground(game, battle)
  battle=GoldCompat.sourceBattleState(battle)
  if not (game and game.stack and battle) then return false end
  local top = game.stack.top and game.stack:top()
      or (game.stack.states and game.stack.states[#game.stack.states])
  return top == battle
end

local function shouldDrawStatusHUD(game, battle)
  -- Bag, Party, Summary, Naming, etc. are pushed above BattleState. When one
  -- owns the foreground, no battle status chrome should leak over it.
  if not battleOwnsForeground(game, battle) then return false end

  -- Keep the status HUD visible during move selection too, so the plates and
  -- the move menu all fit on one screen at minimum window size.
  return true
end

local function enemyVisible(battle)
  if not battle or not battle.enemy then return false end
  if battle.__gen2 then
    local src=battle.__gen3Source
    return src and src.showEnemyHud and not battle.showEnemyTrainer
        and not battle.enemy.fainted
  end
  if battle.showEnemyTrainer or battle.enemySendingOut then return false end
  if battle.enemy.fainted or battle.introBalls then return false end
  if battle.growInScale and battle:growInScale(battle.enemy) then return false end
  return (battle.introSlide or 0) == 0
end

local function playerVisible(battle)
  if not battle or not battle.player then return false end
  if battle.__gen2 then
    local src=battle.__gen3Source
    return src and src.showPlayerHud and not battle.showPlayerBack
        and not battle.player.fainted
  end
  if battle.safari or battle.demo or battle.showPlayerBack then return false end
  return (battle.introSlide or 0) == 0
end

local function statusText(battle, battler)
  if not battler or not battler.shownStatus then return nil end
  if battle and battle.statusLabel then
    local ok, label = pcall(battle.statusLabel, battle,
      { status = battler.shownStatus })
    if ok and label and label ~= "" then return tostring(label):upper() end
  end
  return tostring(battler.shownStatus):upper()
end

local function statusColor(label)
  label = tostring(label or ""):upper()
  if label:find("PSN", 1, true) or label:find("TOX", 1, true) then
    return 0.54, 0.18, 0.67, 1
  elseif label:find("PAR", 1, true) then
    return 0.84, 0.59, 0.04, 1
  elseif label:find("BRN", 1, true) then
    return 0.84, 0.26, 0.09, 1
  elseif label:find("FRZ", 1, true) then
    return 0.13, 0.52, 0.76, 1
  elseif label:find("SLP", 1, true) then
    return 0.34, 0.37, 0.42, 1
  end
  return 0.26, 0.26, 0.24, 1
end

local function hpColor(ratio)
  if ratio > 0.50 then return 0.24, 0.79, 0.42, 1 end
  if ratio > 0.20 then return 0.94, 0.68, 0.09, 1 end
  return 0.88, 0.17, 0.12, 1
end

-- -------------------------------------------------------------------------
-- Vanilla battle text/menu visual suppression
-- -------------------------------------------------------------------------

local function runDrawInvisible(fn, self, ...)
  -- Do not skip an engine/mod draw method just because we own its pixels.
  -- Some presentation methods also advance presentation state (for example
  -- BattleState:drawTextArea decays scrollPx). Run them with an empty scissor
  -- so their lifecycle stays native while no legacy pixels reach the frame.
  --
  -- REVERTED (v2.1.16 hotfix): briefly used a large off-canvas negative
  -- scissor rect here instead of (0,0,0,0), on a speculative, never-confirmed
  -- theory about zero-area scissor rects being a degenerate edge case for a
  -- 3D renderer chained off this call. This function is used constantly on
  -- Gen 1 (patchVanillaTextDrawing wraps BattleState.drawTextArea/drawHUDs
  -- with it on every battle-text/menu frame), and that speculative change is
  -- the most likely cause of Gen 1 becoming completely broken right after it
  -- shipped -- large negative coordinates are exactly the kind of value a
  -- fixed-point/GB-style renderer can choke on in ways (0,0,0,0) never did
  -- across many builds of proven-working use. Back to the original, long
  -- confirmed-safe zero-area scissor.
  local g=love.graphics
  g.push("all")
  g.setScissor(0,0,0,0)
  local ok,result=pcall(fn,self,...)
  g.pop()
  if not ok then error(result) end
  return result
end

local function resolveOwnershipBattle(state)
  local battle=state
  if not (battle and (battle.player or battle.enemy or battle.phase
      or GoldCompat.isGen2BattleState(battle))) then
    battle=State.activeBattle
  end
  return battle
end

-- Generic (non-name-based) detection of any other mod that has already
-- claimed the full 3D battle frame for this battle, per the community
-- "PORTABLE_BATTLE_ACTORS.md" self-announcement contract:
--   mod.exports.battleWorld (or the alias mod.exports.battleFullFrame) =
--     {version=1, fullFrame=true, priority=0,
--      status=function(context) return {active=true} end}
-- Any battle-environment/world-renderer mod that publishes this shape is
-- recognized here -- we deliberately never check a specific mod ID, since a
-- name-based carve-out only ever fixes the one mod it was written against.
local function eachLoadedModId(mod)
  local ids={}
  local game=mod and mod.game
  local function addFrom(list)
    if type(list)~="table" then return end
    for _,entry in ipairs(list) do
      local id=type(entry)=="table" and entry.id or entry
      if type(id)=="string" then ids[id]=true end
    end
  end
  addFrom(game and game.modStatus and game.modStatus.loaded)
  local loader=game and game.mods
  if loader and type(loader.status)=="function" then
    local ok,status=pcall(loader.status,loader)
    if ok and type(status)=="table" then addFrom(status.loaded) end
  end
  return ids
end

GoldCompat.fullFrameCandidates=nil

function GoldCompat.refreshFullFrameCandidates(mod)
  local candidates={}
  if not (mod and type(mod.find)=="function") then
    GoldCompat.fullFrameCandidates=candidates
    return candidates
  end

  -- The loaded-mod HANDLE set is stable between loader events/battle entry.
  -- The old path rebuilt loader status, allocated an id table and called
  -- mod.find for every loaded mod several times per battle frame. Cache only
  -- those handles here; read each handle's exports live below. That preserves
  -- compatibility with providers that publish/replace an ownership capability
  -- at runtime while still removing the expensive discovery work from draw.
  for id in pairs(eachLoadedModId(mod)) do
    local okFind,handle=pcall(mod.find,id)
    candidates[#candidates+1]={id=id,handle=okFind and handle or nil}
  end

  GoldCompat.fullFrameCandidates=candidates
  return candidates
end

function GoldCompat.activeFullFrameRenderer(mod,battle)
  if not (mod and type(mod.find)=="function") then return nil end
  local candidates=GoldCompat.fullFrameCandidates
      or GoldCompat.refreshFullFrameCandidates(mod)

  for _,candidate in ipairs(candidates) do
    local handle=candidate.handle
    if not handle and candidate.id then
      -- A loader can report an id a moment before its public handle settles.
      -- Retry only unresolved entries; once found, the hot path stays cached.
      local okFind,resolved=pcall(mod.find,candidate.id)
      if okFind and resolved then
        handle=resolved
        candidate.handle=resolved
      end
    end
    local exports=handle and handle.exports
    if type(exports)=="table" then
      local contract=exports.battleWorld or exports.battleFullFrame

      -- Standard self-announcement contract: handle discovery is cached, but
      -- capability/status are live so runtime ownership transitions still work.
      if type(contract)=="table" and contract.fullFrame then
        local active=true
        if type(contract.status)=="function" then
          local okStatus,result=pcall(contract.status,{battle=battle,game=mod.game})
          active=okStatus and type(result)=="table" and result.active and true or false
        end
        if active then return handle,contract end
      end

      -- presentationOwnership is likewise queried live so CBE/Stadium/portable
      -- providers keep full authority over their own battle lifecycle.
      local ownership=exports.presentationOwnership
      if type(ownership)=="function" then
        local okOwn,result=pcall(ownership,battle)
        if okOwn and type(result)=="table" and result.world then
          return handle,result
        end
      end
    end
  end
  return nil
end

function GoldCompat.shouldDeferNativeSuppression(state)
  -- When a compliant full-frame renderer already owns this battle's world
  -- and native-presentation suppression, our own firewall below must not
  -- also wrap the same native methods. Two independent wrappers racing to be
  -- outermost is what left unfilled/letterboxed battle regions uncomposited
  -- (seen as a solid white box) behind a 3D renderer: whichever wrapper
  -- ended up outermost could short-circuit before the renderer's own
  -- ownership/background logic ran. Stepping aside entirely removes that
  -- race -- our render.hud chrome still draws on top regardless.
  local battle=resolveOwnershipBattle(state)
  if not battle then return false end
  local mod=GoldCompat.mod
  if not mod then return false end
  return GoldCompat.activeFullFrameRenderer(mod,battle)~=nil
end

function GoldCompat.ownsNativeBattleLayer(state)
  -- Single native-UI ownership predicate used by launcher hooks, engine
  -- methods and third-party presentation contracts.
  --
  -- HARD INVARIANT (3.0.0): HIDE NATIVE BATTLE UI wins BEFORE full-frame
  -- provider deferral. A CBE/Stadium/portable world renderer may own the
  -- battlefield, camera and actors, but that can never be interpreted as
  -- permission for Gen1Recomp's original HUD/text/menu chrome to reappear.
  -- Normal revampedBattleUI ownership still defers to a compliant full-frame
  -- renderer to avoid the historical double-wrapper/white-box race.
  local battle=resolveOwnershipBattle(state)
  if battle==nil then return false end
  if featureEnabled("hideNativeBattleUI") then return true end
  if not featureEnabled("revampedBattleUI") then return false end
  if GoldCompat.shouldDeferNativeSuppression(battle) then return false end
  return true
end

function GoldCompat.hidesAllNativeBattlePresentation(state)
  -- Narrower than ownsNativeBattleLayer(): true only for the explicit HIDE
  -- NATIVE BATTLE UI hard-suppress toggle, never for the default-on BATTLE UI
  -- (revampedBattleUI) reskin toggle. Use this for any hook that asks a
  -- third-party mod to suppress its ENTIRE presentation (sprites included),
  -- since that must stay opt-in -- see the Battle Art suppressHook wiring.
  local battle=resolveOwnershipBattle(state)
  return battle~=nil and featureEnabled("hideNativeBattleUI")
end

-- Colosseum Battle Environments (CBE), when its own COLOSSEUM MODELS toggle
-- is on (CBE's own default), makes its own 3D Pokemon actors authoritative
-- for battle presentation and skips handing Battle Art (or any other resolved
-- sprite provider) a turn at all -- see CBE's CurrentSpriteModels.lua
-- (cbePokemonActorService/desiredPresentation) and BattleSettings.lua. That
-- behavior is designed for CBE's sibling Colosseum Inspired UI overhaul,
-- which is built around CBE's own 3D showroom presentation. It is not what
-- this mod wants: Gen 3 Inspired UI keeps Battle Art (or whichever sprite
-- provider actually resolves) authoritative even when CBE is loaded.
--
-- CBE exposes no per-consumer opt-out of this (no exported way to ask it to
-- defer just for one UI mod), so the only lever is its own persisted
-- COLOSSEUM MODELS preference, which lives in plain save data at
-- game.save.colosseumBattle.pokemonModelsEnabled -- exactly what CBE's own
-- BATTLE settings menu toggles (see its pokemonModelsToggle.onSelect, which
-- does nothing but flip that same field; CBE relies on the engine's normal
-- save-write cycle to persist it, so this does too).
--
-- This nudges that preference from CBE's default (ON) to OFF exactly ONCE
-- per save, the first time CBE is seen loaded alongside this mod, and never
-- touches it again afterward (tracked by its own marker on the same table).
-- If the user later reopens CBE's own BATTLE menu and turns COLOSSEUM MODELS
-- back on themselves, that choice is respected from then on -- this is a
-- one-time default correction for this mod's use case, never an ongoing
-- fight over a setting the user (or CBE's sibling UI mod) may want back on.
function GoldCompat.stepAsideForCbeColosseumModels(mod)
  local game=mod and mod.game
  local save=game and game.save
  if not save then return end

  local prefs=save.colosseumBattle
  if type(prefs)=="table" and prefs.__gen3uiColosseumModelsHandled then return end
  if not (mod.find and mod.find("COLOSSEUM_BATTLE_ENVIRONMENTS")) then return end

  if type(prefs)~="table" then
    prefs={}
    save.colosseumBattle=prefs
  end
  prefs.__gen3uiColosseumModelsHandled=true

  if prefs.pokemonModelsEnabled==nil or prefs.pokemonModelsEnabled==true then
    prefs.pokemonModelsEnabled=false
    if mod.log then
      mod.log:info("Gen 3 UI: Colosseum Battle Environments detected -- set its "
        .."COLOSSEUM MODELS preference to OFF once, so Battle Art/portable "
        .."sprite providers stay authoritative under this UI instead of CBE's "
        .."own 3D actors (that suppression is meant for its sibling Colosseum "
        .."UI overhaul). CBE's own BATTLE menu can turn it back on at any "
        .."time; this mod will not override it again.")
    end
  end
end

function GoldCompat.installBattlePredicateGuard(class,name,slot)
  if not (type(class)=="table" and type(class[name])=="function") then
    return false
  end
  local current=class[name]
  if current==State[slot] then return false end
  local inner=current
  local wrapper=function(self,...)
    if GoldCompat.ownsNativeBattleLayer(self) then return false end
    return inner(self,...)
  end
  State[slot]=wrapper
  class[name]=wrapper
  return true
end

function GoldCompat.installBattleUiFirewall()
  -- Other renderer mods may replace these methods after our chunk loads. This
  -- idempotent firewall wraps whichever implementation is current, and is safe
  -- to reassert at mods.loaded and at every battle boundary.
  if GoldCompat.generation=="gen1" then
    GoldCompat.installBattlePredicateGuard(BattleState,"bottomUIVisible",
      "__gen3uiGen1BottomPredicate")
    GoldCompat.installBattlePredicateGuard(BattleState,"statusHUDVisible",
      "__gen3uiGen1StatusPredicate")

    if type(BattleState.drawHUDs)=="function"
        and BattleState.drawHUDs~=State.__gen3uiGen1HudFirewall then
      local inner=BattleState.drawHUDs
      local wrapper=function(self,...)
        if GoldCompat.ownsNativeBattleLayer(self) then
          return runDrawInvisible(inner,self,...)
        end
        return inner(self,...)
      end
      State.__gen3uiGen1HudFirewall=wrapper
      BattleState.drawHUDs=wrapper
    end
  else
    local okGold,GoldBattleState=pcall(require,"src.ui.gen2.BattleState")
    if okGold and type(GoldBattleState)=="table" then
      GoldCompat.installBattlePredicateGuard(GoldBattleState,"bottomUIVisible",
        "__gen3uiGen2BottomPredicate")
      GoldCompat.installBattlePredicateGuard(GoldBattleState,"statusHUDVisible",
        "__gen3uiGen2StatusPredicate")
    end
  end
end

function GoldCompat.patchShapeHudCompat(mod,id,slot,label)
  if GoldCompat.generation~="gen1" or not (mod and mod.find) then return end
  local handle=mod.find(id)
  local V=handle and handle.exports and handle.exports.lib
  if not (V and type(V.require)=="function") then return end
  local ok,OverworldBattle=pcall(V.require,"OverworldBattle")
  if not (ok and type(OverworldBattle)=="table") then return end

  local key="__gen3uiDynamicHudCompat_"..slot
  local compat=OverworldBattle[key]
  if type(compat)~="table" then compat={}; OverworldBattle[key]=compat end
  local snap=OverworldBattle.snapHUDs
  if type(snap)=="function" and snap~=compat.snapWrapper then
    local inner=snap
    local wrapper=function(battle,shot,...)
      if GoldCompat.ownsNativeBattleLayer(battle) then return false end
      return inner(battle,shot,...)
    end
    compat.snapWrapper=wrapper
    OverworldBattle.snapHUDs=wrapper
  end
  local panels=OverworldBattle.drawHudPanels
  if type(panels)=="function" and panels~=compat.panelWrapper then
    local inner=panels
    local wrapper=function(battle,...)
      if GoldCompat.ownsNativeBattleLayer(battle) then return end
      return inner(battle,...)
    end
    compat.panelWrapper=wrapper
    OverworldBattle.drawHudPanels=wrapper
  end
  if not compat.logged and mod.log then
    compat.logged=true
    mod.log:info("Gen 3 UI: "..label.." battle-HUD firewall active")
  end
end

local function patchVanillaTextDrawing()
  -- Gold has a separate BattleState implementation. Its presentation is
  -- handled by the shared battle.overlay/render.hud compatibility path below;
  -- do not attach Gen 1 drawTextArea/drawHUDs assumptions to the facade.
  if GoldCompat.generation=="gen2" then return end

  -- These wrappers preserve lifecycle behavior while suppressing native pixels.
  -- (v2.1.21: the comment that used to be here claimed a separate
  -- "battle.overlay scrub" was the authoritative anti-duplicate guard --
  -- battleOverlayHook below has been a pure pass-through since the White Box
  -- saga fix (it deliberately never paints over the battlefield anymore), so
  -- these two wrappers are in fact the ONLY suppression path for Gen 1's
  -- classic corner HUD boxes and bottom text/command area. That stale comment
  -- is exactly what let the bug below go unnoticed for this long.)
  if vanillaTextPatched then return end
  vanillaTextPatched = true

  -- Chain whatever implementation exists when this mod loads.
  local originalTextArea = BattleState.drawTextArea
  if originalTextArea then
    BattleState.drawTextArea = function(self, ...)
      -- Hard override: when requested, every native battle text-area draw still
      -- runs for lifecycle/state purposes but no legacy pixels can reach frame.
      --
      -- FOUND (v2.1.21): this used to open with
      -- `if GoldCompat.shouldDeferNativeSuppression(self) then return
      -- originalTextArea(self,...) end` -- stepping aside and calling native
      -- DIRECTLY (no suppression at all) whenever a compliant full-frame 3D
      -- battle renderer (e.g. Colosseum Battle Environments) was detected,
      -- trusting that renderer to suppress the classic 2D chrome itself.
      -- Confirmed wrong by a direct user screenshot: native's own
      -- "FIGHT/ITEM..." command box was fully visible right next to this
      -- mod's own revamped FIGHT/POKéMON/BAG/RUN menu during an active CBE
      -- battle -- CBE's own full-frame contract apparently covers the 3D
      -- world/actors only, not this. Removed the bypass entirely: this now
      -- always uses runDrawInvisible below when suppression is requested,
      -- exactly matching the pattern already proven safe for Gold's
      -- drawStatsBox/drawPanel (GoldCompat.installGoldBattlePresentation) --
      -- runDrawInvisible only ever discards THIS call's own rendered pixels
      -- via a zero-area scissor, it never paints over anything, so it cannot
      -- blank a 3D renderer's scene unless that renderer's own world draw is
      -- literally nested inside this exact call (already shown not to be the
      -- case for Gold's equivalent methods, and there is no reason to expect
      -- otherwise here). HIDE NATIVE BATTLE UI is meant to be an absolute
      -- rule -- no exceptions for a third-party renderer being active.
      if featureEnabled("hideNativeBattleUI") then
        return runDrawInvisible(originalTextArea,self,...)
      end

      if not battleUiPresentationEnabled() then
        return originalTextArea(self, ...)
      end

      if self.phase=="messages"
          or (self.phase=="menu" and not self.safari and not self.demo)
          or self.phase=="moveSelect" then
        return runDrawInvisible(originalTextArea,self,...)
      end

      return originalTextArea(self,...)
    end
  end

  local originalHUDs = BattleState.drawHUDs
  if originalHUDs then
    BattleState.drawHUDs = function(self, slide, ...)
      -- See the matching comment on drawTextArea above (v2.1.21): the
      -- shouldDeferNativeSuppression bypass that used to sit here let native's
      -- enemy/player name+HP corner boxes draw in full, unsuppressed, during a
      -- CBE battle -- confirmed by the same user screenshot. Removed for the
      -- same reason: runDrawInvisible is safe unconditionally.
      if not battleUiPresentationEnabled() then
        return originalHUDs(self,slide,...)
      end

      -- Preserve the complete native/modded HUD draw lifecycle without letting
      -- its pixels through. Some other mods also hang behavior off drawHUDs().
      runDrawInvisible(originalHUDs,self,slide,...)
    end
  end

  -- Trainer party count belongs to the OPENING battle presentation, not the
  -- persistent battle HUD. Draw it directly after BattleState.draw() while
  -- Gen1Recomp's own introBalls flag is active. This runs on the same battle
  -- surface as the intro itself, after the suppressed native HUD has finished.
  local originalBattleDraw = BattleState.draw
  if originalBattleDraw then
    BattleState.draw = function(self, ...)
      local result=originalBattleDraw(self,...)

      if battleUiPresentationEnabled()
          and self.introBalls
          and type(self.enemyParty)=="table"
          and #self.enemyParty>0 then
        local g=love.graphics
        g.push("all")

        local wide=false
        if self.wideLayout then
          local ok,value=pcall(self.wideLayout,self)
          wide=ok and value or false
        end

        local x0=wide and 88 or 64
        local y0=wide and 40 or 16
        local gap=-8
        local r=3.2

        g.setColor(0.10,0.10,0.10,0.95)
        g.rectangle("fill",wide and 41 or 17,wide and 46 or 22,54,2)

        -- FOUND: this always drew 6 ball slots regardless of the trainer's
        -- actual party size, padding out any smaller party with faded hollow
        -- placeholder balls that don't correspond to anything -- Gen 2's
        -- equivalent (GoldCompat.drawEnemyTrainerPartyIndicator) correctly
        -- loops only 1..total (total=#party). A 3-Pokemon Gen 1 trainer was
        -- showing 3 real balls plus 3 phantom empty ones.
        for i=1,#self.enemyParty do
          local mon=self.enemyParty[i]
          local cx=x0+(i-1)*gap
          if mon then
            local alive=(mon.hp or 0)>0
            g.setColor(alive and {0.92,0.18,0.14,1}
                             or {0.42,0.42,0.40,0.85})
            g.arc("fill","pie",cx,y0,r,math.pi,math.pi*2)
            g.setColor(0.96,0.96,0.92,1)
            g.arc("fill","pie",cx,y0,r,0,math.pi)
            g.setColor(0.08,0.08,0.08,1)
            g.setLineWidth(0.8)
            g.circle("line",cx,y0,r)
            g.line(cx-r,y0,cx+r,y0)
            g.setColor(0.98,0.98,0.95,1)
            g.circle("fill",cx,y0,0.9)
            g.setColor(0.08,0.08,0.08,1)
            g.circle("line",cx,y0,0.9)
          end
        end

        g.pop()
      end

      return result
    end
  end
end

-- -------------------------------------------------------------------------
-- Assets and smooth screen fonts
-- -------------------------------------------------------------------------

local function font(size)
  size = math.max(4, math.floor(size + 0.5))
  if fonts[size] then return fonts[size] end

  local ok, f = pcall(love.graphics.newFont,
    EngineFont.PLAINPIXEL, size, "normal")
  if not ok or not f then
    local fallback = love.graphics.getFont()
    fonts[size] = fallback
    return fallback
  end

  if f.setFilter then pcall(f.setFilter, f, "linear", "linear") end
  fonts[size] = f
  return f
end

-- EngineFont.PLAINPIXEL (like most rasterized fonts) bakes in real ascent
-- and descent padding, so its actual getHeight() is noticeably taller than
-- the nominal "size" passed to love.graphics.newFont. Bag/Pack row
-- backgrounds were sized as if glyph height == nominal size, so the real
-- glyph box ran taller than its highlight and visually spilled out of it
-- (looked "off-center"/cut through by the row divider). Measure the font's
-- real per-pixel height ratio once at a large reference size (stable
-- regardless of the actual requested size for a scalable font) so row
-- geometry can be sized from real metrics instead of a guessed constant.
local fontHeightRatio=nil
local function fontHeightPerPixel()
  if not fontHeightRatio then
    fontHeightRatio=font(100):getHeight()/100
  end
  return fontHeightRatio
end

-- Real vertical footprint (in the same *virtual* 160x144 canvas units the
-- Bag/Pack row background rects use) of one row label at the current
-- TEXT SIZE, independent of window scale/sc: dividing a real screen-pixel
-- font height by sc and multiplying a virtual size by sc cancel out.
-- Generalized version of the same real-metric approach, parameterized by
-- the actual nominal label size a given list renders at (not every list in
-- this file draws its row labels at Bag/Pack's own 4.5 -- a General Sweep
-- across every restyled selection list (v2.1.28) found roughly a dozen
-- menus with their OWN hand-picked constant row height instead of this
-- calculation, which meant only some menus actually grew/shrunk their
-- selection highlight and row spacing to match the user's TEXT SIZE /
-- TEXT THICKNESS settings -- the rest stayed a fixed pixel height forever,
-- so a highlight could run shorter than its own label at larger settings
-- (or sit with excess dead space at smaller ones) depending on which menu
-- you were in. Every one of those has been switched to call this with its
-- own real label size, so the growth/shrink behavior is now identical
-- everywhere rather than only in the menus this was originally written for.
function GoldCompat.dynamicRowHeight(nominalSize,minH,pad)
  nominalSize=nominalSize or 4.5
  pad=pad or 3
  minH=minH or 10
  local textH=fontHeightPerPixel()*nominalSize*UI_TEXT_SCALE*GoldCompat.userTextScale()
  return math.max(minH,math.ceil(textH)+pad)
end

function GoldCompat.bagPackRowHeight()
  local nominal=4.5 -- logical size GoldCompat.panelText uses for row labels
  return GoldCompat.dynamicRowHeight(nominal,10,3)
end

local function printText(text, x, y, size, color, align, width)
  local g = love.graphics
  local scaledSize=math.max(4,(tonumber(size) or 4)*UI_TEXT_SCALE*GoldCompat.userTextScale())
  local f = font(scaledSize)
  local old = g.getFont()
  g.setFont(f)

  text = tostring(text or "")
  color = color or {0.11,0.12,0.11,1}
  local shadow = {0.14,0.16,0.13,0.24}

  if width and not text:find("[\r\n]") then
    -- Selection rows are single-line controls. LÖVE's printf wraps an
    -- oversized label onto another row, which lets it escape the highlight
    -- window. Fit first, then clip the final minimum-size fallback horizontally.
    local available=math.max(1,width-2-GoldCompat.userTextWeight())
    while scaledSize>4 and f:getWidth(text)>available do
      scaledSize=scaledSize-1
      f=font(scaledSize)
      g.setFont(f)
    end
    local tw=f:getWidth(text)
    local tx=x
    if align=="center" then tx=x+(width-tw)*0.5
    elseif align=="right" then tx=x+width-tw end

    local oldScissor
    if type(g.getScissor)=="function" and type(g.setScissor)=="function" then
      oldScissor={g.getScissor()}
      local cx,cy,cw,ch=x,0,width,g.getHeight()
      if oldScissor[1] then
        local ox1,oy1=math.max(cx,oldScissor[1]),math.max(cy,oldScissor[2])
        local ox2=math.min(cx+cw,oldScissor[1]+oldScissor[3])
        local oy2=math.min(cy+ch,oldScissor[2]+oldScissor[4])
        cx,cy,cw,ch=ox1,oy1,math.max(0,ox2-ox1),math.max(0,oy2-oy1)
      end
      g.setScissor(cx,cy,cw,ch)
    end

    g.setColor(shadow); g.print(text,tx+1,y+1)
    g.setColor(color); g.print(text,tx,y)
    g.print(text,tx+GoldCompat.userTextWeight(),y)

    if oldScissor then
      if oldScissor[1] then g.setScissor(unpack(oldScissor)) else g.setScissor() end
    end
  elseif width then
    g.setColor(shadow); g.printf(text,x+1,y+1,width,align or "left")
    g.setColor(color); g.printf(text,x,y,width,align or "left")
    g.printf(text,x+GoldCompat.userTextWeight(),y,width,align or "left")
  else
    g.setColor(shadow)
    g.print(text, x+1, y+1)
    g.setColor(color)
    g.print(text, x, y)
    g.print(text, x+GoldCompat.userTextWeight(), y)
  end

  if old then g.setFont(old) end
  g.setColor(1,1,1,1)
end


local function fittedDialogueMetrics(lines, preferred, minimum, maxWidth, maxHeight)
  local size=math.max(minimum or 4,preferred or 4)
  local floorSize=math.max(4,minimum or 4)
  local visible=math.max(1,#(lines or {}))

  while size > floorSize do
    local f=font(size*UI_TEXT_SCALE*GoldCompat.userTextScale())
    local fitsWidth=true
    for i=1,visible do
      if f:getWidth(tostring(lines[i] or "")) + 4 > maxWidth then
        fitsWidth=false
        break
      end
    end

    -- Use the font's ACTUAL line box rather than assuming fontSize == height.
    local glyphH=f:getHeight()
    local lineH=math.ceil(glyphH*1.10)
    local blockH=glyphH + math.max(0,visible-1)*lineH

    if fitsWidth and blockH <= maxHeight then
      return size,glyphH,lineH,blockH
    end
    size=size-1
  end

  local f=font(floorSize*UI_TEXT_SCALE*GoldCompat.userTextScale())
  local glyphH=f:getHeight()
  local lineH=math.ceil(glyphH*1.08)
  local blockH=glyphH + math.max(0,visible-1)*lineH
  return floorSize,glyphH,lineH,blockH
end

-- BattleState.current.text is already the actual localized, human-readable
-- message string. The engine only converts it to glyph codes for the vanilla
-- typewriter. Using the source string avoids lossy reverse-charmap decoding.
local function splitBattleMessageText(text)
  text=tostring(text or "")
  local out={}
  local pos=1
  while true do
    local s,e=text:find("[\n\v]",pos)
    if not s then
      out[#out+1]=text:sub(pos)
      break
    end
    out[#out+1]=text:sub(pos,s-1)
    pos=e+1
  end
  return out
end

function GoldCompat.revealedGlyphText(source, count)
  source=tostring(source or "")
  count=math.max(0,tonumber(count) or 0)
  if count==0 then return "" end

  -- EngineFont.split uses the exact active Gen1Recomp charmap, so multi-byte
  -- glyphs such as é and mod-provided glyph sequences stay intact.
  local spans=EngineFont.split(source)
  if count>=#spans then return source end
  local last=spans[count]
  return last and source:sub(1,last.to) or ""
end

local function messageLines(battle)
  if battle and battle.__gen2 then
    local msg=tostring(battle.message or
      (battle.current and battle.current.text) or "")
    if msg=="" then return battle.__gen3VisibleMessageLines or {} end
    local out={}
    for line in msg:gmatch("[^\n\v]+") do out[#out+1]=line end
    if #out==0 then out[1]=msg end
    battle.__gen3VisibleMessageLines=out
    battle.__gen3FullMessageLines=out
    return out
  end

  -- BattleState.shown is THE engine's rendered rolling two-line window.
  -- Do not reconstruct CONT/newline state ourselves. `shown` already accounts
  -- for typing progress, beginMsgLine(), CONT scrolling, and sayChoice pages.
  local shown=battle and battle.shown or nil
  -- CONFIRMED against the real src/battle/BattleState.lua: the item pushed
  -- into `self.current` keeps the ORIGINAL, unstripped message text --
  -- BattleState:startMessage builds its own rendered `self.lines` from
  -- `require("src.render.TextBox").strip(item.text)`, but never mutates
  -- `item.text`/`self.current.text` itself. Reading `battle.current.text`
  -- straight (as this function always has) carries the raw trailing
  -- "{PROMPT}"/"{DONE}" tail-command markers straight into whatever this mod
  -- displays -- exactly the literal "{PROMPT}" text reported showing up at
  -- the end of battle messages ("Wild PIDGEY appeared!{PROMPT}"). Stripping
  -- here matches what the engine's own renderer already does before typing
  -- a line, using the same TextBox.strip() Gen 1's shared TextBox/BattleState
  -- text pipeline defines it in.
  local source=battle and battle.current and battle.current.text or nil
  if source then source=TextBox.strip(source) end

  if shown and source and #shown>0 then
    local sourceLines=splitBattleMessageText(source)
    local lineIndex=math.max(1,tonumber(battle.lineIndex) or 1)
    local firstSource=math.max(1,lineIndex-#shown+1)
    local out={}

    local pageComplete =
      battle.msgWaiting
      or battle.msgPrompt
      or battle.msgHold
      or (battle.current and battle.current.done)

    for visibleIndex,codes in ipairs(shown) do
      local sourceIndex=firstSource+visibleIndex-1
      local full=sourceLines[sourceIndex] or ""

      -- At the completed/waiting state the source string is authoritative.
      -- Turbo/fast-forward can advance shown-code bookkeeping a frame behind
      -- the visible page, which previously dropped the final few glyphs.
      -- Keep this function faithful to native typewriter line ownership.
      -- Completed pages are rewrapped later in drawDialogue using the actual
      -- display font and content width.
      out[#out+1]=GoldCompat.revealedGlyphText(full,#(codes or {}))
    end

    battle.__gen3VisibleMessageLines=out
    return out
  end

  -- Animations may deliberately retain the prior typed page after current is
  -- cleared; mirror BattleState.drawTextArea's msgHold behavior.
  return (battle and battle.__gen3VisibleMessageLines) or {}
end

function GoldCompat.messagePageFullLines(battle)
  if battle and battle.__gen2 then
    return messageLines(battle)
  end
  -- Same fix as messageLines above: strip the raw {PROMPT}/{DONE} tail
  -- markers before splitting, matching the engine's own TextBox.strip step.
  local source=battle and battle.current and battle.current.text or nil
  if source then source=TextBox.strip(source) end
  local shown=battle and battle.shown or nil
  if not source or not shown or #shown==0 then
    return battle and battle.__gen3FullMessageLines or {}
  end

  local sourceLines=splitBattleMessageText(source)
  local lineIndex=math.max(1,tonumber(battle.lineIndex) or 1)
  local firstSource=math.max(1,lineIndex-#shown+1)
  local out={}
  for i=1,#shown do
    out[#out+1]=sourceLines[firstSource+i-1] or ""
  end

  battle.__gen3FullMessageLines=out
  return out
end

local function wrapCompletedBattleLines(sourceLines,size,maxWidth)
  local f=font(size*UI_TEXT_SCALE*GoldCompat.userTextScale())
  local out={}

  for _,line in ipairs(sourceLines or {}) do
    line=tostring(line or "")
    local _,wrapped=f:getWrap(line,math.max(1,maxWidth))
    if type(wrapped)=="table" and #wrapped>0 then
      for _,part in ipairs(wrapped) do
        out[#out+1]=part
      end
    else
      out[#out+1]=line
    end
  end

  if #out==0 then out[1]="" end
  return out
end

function GoldCompat.fittedCompletedDialogue(sourceLines,preferred,minimum,maxWidth,maxHeight)
  local size=math.max(minimum or 4,preferred or 4)
  local floorSize=math.max(4,(minimum or 4)*0.88)

  while size>floorSize do
    local wrapped=wrapCompletedBattleLines(sourceLines,size,maxWidth)
    local f=font(size*UI_TEXT_SCALE*GoldCompat.userTextScale())
    local glyphH=f:getHeight()
    local lineH=math.ceil(glyphH*1.10)
    local visible=math.min(2,#wrapped)
    local blockH=glyphH + math.max(0,visible-1)*lineH

    if #wrapped<=2 and blockH<=maxHeight then
      return size,glyphH,lineH,blockH,wrapped
    end
    size=size-1
  end

  local wrapped=wrapCompletedBattleLines(sourceLines,floorSize,maxWidth)
  local f=font(floorSize*UI_TEXT_SCALE*GoldCompat.userTextScale())
  local glyphH=f:getHeight()
  local lineH=math.ceil(glyphH*1.08)
  local visible=math.min(2,#wrapped)
  local blockH=glyphH + math.max(0,visible-1)*lineH
  return floorSize,glyphH,lineH,blockH,wrapped
end


local function displayName(battler)
  local raw = battler and (
    battler.name
    or (battler.mon and battler.mon.nickname)
    or (battler.mon and battler.mon.name)
  )
  return tostring(raw or "POKEMON")
end

local function roundedRect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x, y, w, h, r, r)
end

local UI_BORDER_COLORS = {
  gold   = {0.72,0.58,0.30,1},
  red    = {0.78,0.18,0.16,1},
  orange = {0.90,0.43,0.12,1},
  yellow = {0.88,0.72,0.14,1},
  green  = {0.19,0.62,0.30,1},
  cyan   = {0.14,0.65,0.70,1},
  blue   = {0.18,0.42,0.78,1},
  purple = {0.48,0.27,0.68,1},
  pink   = {0.82,0.37,0.57,1},
  brown  = {0.47,0.30,0.17,1},
  gray   = {0.46,0.47,0.45,1},
  white  = {0.91,0.91,0.87,1},
  black  = {0.08,0.08,0.07,1},
}

function GoldCompat.currentBorderColor()
  local cached=GoldCompat.derivedOptionCache.borderColor
  if cached~=nil then return cached end
  local value=UI_BORDER_COLORS[optionValue("uiBorderColor")] or UI_BORDER_COLORS.gold
  GoldCompat.derivedOptionCache.borderColor=value
  return value
end

local function setCurrentBorderColor(alpha)
  local c = GoldCompat.currentBorderColor()
  love.graphics.setColor(c[1],c[2],c[3],alpha or 1)
end

function GoldCompat.currentBorderStyle()
  local cached=GoldCompat.derivedOptionCache.borderStyle
  if cached~=nil then return cached end
  local value=optionValue("uiBorderStyle") or "classic"
  GoldCompat.derivedOptionCache.borderStyle=value
  return value
end

local function borderLine(x,y,w,h,r)
  if r and r > 0 then
    roundedRect("line",x,y,w,h,r)
  else
    love.graphics.rectangle("line",x,y,w,h)
  end
end

local function drawUnifiedBorder(x,y,w,h,r)
  local g = love.graphics
  local style = GoldCompat.currentBorderStyle()
  r = r or 0
  setCurrentBorderColor(1)
  g.setLineWidth(1)

  if style == "minimal" then
    g.line(x+3,y+h-3,x+w-3,y+h-3)

  elseif style == "double" then
    borderLine(x+2,y+2,w-4,h-4,math.max(0,r-1))
    borderLine(x+4,y+4,w-8,h-8,math.max(0,r-2))

  elseif style == "bold" then
    g.setLineWidth(3)
    borderLine(x+3,y+3,w-6,h-6,math.max(0,r-2))

  elseif style == "dashed" then
    for xx=x+3,x+w-5,6 do
      g.line(xx,y+3,math.min(xx+3,x+w-3),y+3)
      g.line(xx,y+h-3,math.min(xx+3,x+w-3),y+h-3)
    end
    for yy=y+3,y+h-5,6 do
      g.line(x+3,yy,x+3,math.min(yy+3,y+h-3))
      g.line(x+w-3,yy,x+w-3,math.min(yy+3,y+h-3))
    end

  elseif style == "dotted" then
    for xx=x+3,x+w-3,5 do
      g.points(xx,y+3)
      g.points(xx,y+h-3)
    end
    for yy=y+3,y+h-3,5 do
      g.points(x+3,yy)
      g.points(x+w-3,yy)
    end

  elseif style == "striped" then
    for xx=x+3,x+w-7,7 do
      g.polygon("fill",xx,y+2,xx+3,y+2,xx+6,y+5,xx+3,y+5)
      g.polygon("fill",xx,y+h-5,xx+3,y+h-5,xx+6,y+h-2,xx+3,y+h-2)
    end
    g.rectangle("fill",x+2,y+3,2,h-6)
    g.rectangle("fill",x+w-4,y+3,2,h-6)

  elseif style == "checker" then
    for xx=x+3,x+w-5,5 do
      if math.floor((xx-x)/5)%2 == 0 then
        g.rectangle("fill",xx,y+2,3,3)
        g.rectangle("fill",xx,y+h-5,3,3)
      end
    end
    for yy=y+3,y+h-5,5 do
      if math.floor((yy-y)/5)%2 == 1 then
        g.rectangle("fill",x+2,yy,3,3)
        g.rectangle("fill",x+w-5,yy,3,3)
      end
    end

  else -- classic
    borderLine(x+3,y+3,w-6,h-6,math.max(0,r-2))
  end

  g.setLineWidth(1)
  g.setColor(1,1,1,1)
end


-- -------------------------------------------------------------------------
-- Status HUD
-- -------------------------------------------------------------------------

local function hudScale()
  local sw,sh=love.graphics.getDimensions()
  local raw=math.min(sw/430,sh/245)

  local scale
  if raw <= 4.5 then
    -- Lower the HUD min scale to 1.78 so the plates fit on their own side at
    -- small windows without overlapping the DV reader or the screen edge.
    -- Middle-crossing clamps keep enemy left / player right.
    scale=clamp(raw,1.78,3.85)
  else
    scale=clamp(3.85 + (raw-4.5)*0.72,3.85,7.0)
  end
  return scale*GoldCompat.userBoxScale()
end

local function drawPlate(x, y, w, h, s)
  local g = love.graphics
  local radius = 7*s

  -- Dark green-gray frame.
  g.setColor(0.24,0.31,0.28,1)
  roundedRect("fill", x, y, w, h, radius)

  -- Cream face.
  g.setColor(0.965,0.945,0.86,1)
  roundedRect("fill", x+2.4*s, y+2.4*s, w-4.8*s, h-4.8*s, radius-1.5*s)

  -- Inner highlight.
  g.setColor(1.0,0.99,0.94,0.9)
  g.setLineWidth(math.max(1.2,0.7*s))
  roundedRect("line", x+4*s, y+4*s, w-8*s, h-8*s, radius-2*s)
  -- Themed outer border intentionally omitted so the plates align flush at
  -- the screen margins without the colored ring; no drop shadow either.
end

local function drawStyledHP(x, y, w, h, battler)
  local g = love.graphics
  local hp, mx = shownHP(battler), maxHP(battler)
  local ratio = clamp(hp / mx, 0, 1)

  -- Dark HP capsule.
  local badgeW = h * 1.95
  g.setColor(0.18,0.31,0.29,1)
  roundedRect("fill", x, y, badgeW, h, h*0.38)

  -- Center HP against the actual capsule/bar geometry. The old y+h*0.00
  -- offset made the label ride high relative to the HP bar.
  local hpTextSize = h*0.68
  local hpFont = font(hpTextSize*UI_TEXT_SCALE)
  local hpTextH = hpFont and hpFont:getHeight() or hpTextSize

  -- Pixel fonts carry extra ascent/descent padding. Pull the baseline up by a
  -- fifth of the capsule height so the visible H/P pixels, not the nominal font
  -- box, are vertically centered against the adjoining health rail.
  local hpPadX = h*0.18
  local hpTextY = y + math.max(0,(h-hpTextH)*0.5) - h*0.20
  printText("HP", x+hpPadX, hpTextY, hpTextSize,
            {0.96,0.72,0.18,1},"center",badgeW-hpPadX*2)

  local bx = x + badgeW - h*0.20
  local bw = w - badgeW + h*0.20

  g.setColor(0.18,0.24,0.22,1)
  roundedRect("fill", bx,y,bw,h,h*0.38)
  -- Dark empty track so the green/yellow HP fill stays high-contrast and
  -- easy to read at a glance.
  g.setColor(0.26,0.28,0.26,1)
  roundedRect("fill", bx+2,y+2,bw-4,h-4,math.max(2,h*0.27))

  local innerW = math.max(0,bw-4)
  local fillW = innerW * ratio
  if hp > 0 then fillW = math.max(2,fillW) end
  if fillW > 0 then
    local r,gg,b,a = hpColor(ratio)
    g.setColor(r,gg,b,a)
    roundedRect("fill", bx+2,y+2,fillW,h-4,math.max(2,h*0.25))
    g.setColor(math.min(1,r+0.18),math.min(1,gg+0.18),
               math.min(1,b+0.18),0.80)
    roundedRect("fill",bx+4,y+3,math.max(0,fillW-4),
                math.max(2,(h-4)*0.28),2)
  end
end

function GoldCompat.drawEXPRow(plateX, plateY, plateW, plateH, battle, battler, s)
  local g = love.graphics
  local ratio = GoldCompat.safeExpRatio(battle, battler)

  -- Exact player-plate-relative geometry.
  local left = plateX + 7*s
  local right = plateX + plateW - 6*s
  local barH = 4.6*s
  -- EXP row in pure logical units (no fixed pixels) so it stays aligned with
  -- the HP readout at every resolution. Sits 6*s above the box bottom, clear
  -- of both the HP bar/readout above and the box edge below.
  local rowY = plateY + plateH - 10*s

  -- Rail starts at the HP bar's start and is 140% of its previous (half)
  -- span (=70% of full width), fitting beside any 3-digit HP readout.
  local barX = plateX + 8*s
  local barW = math.max(8*s, (right - barX) * 0.70)

  -- Outer dark teal capsule.
  g.setColor(0.10,0.20,0.23,1)
  roundedRect("fill", barX, rowY, barW, barH, 2.0*s)

  -- Blue-tinted empty track so the EXP row is recognizable even at 0%.
  local pad = 0.9*s
  local ix = barX + pad
  local iy = rowY + pad
  local iw = math.max(1, barW - pad*2)
  local ih = math.max(1, barH - pad*2)

  g.setColor(0.18,0.31,0.43,1)
  roundedRect("fill", ix, iy, iw, ih, 1.2*s)

  -- Live blue EXP fill.
  local fw = iw * ratio
  if fw > 0 then
    g.setColor(0.03,0.39,0.96,1)
    roundedRect("fill", ix, iy, fw, ih, 1.2*s)

    -- Cyan highlight gives it the FireRed/GBA gloss.
    g.setColor(0.40,0.80,1.00,0.98)
    roundedRect("fill",
                ix + 0.4*s,
                iy + 0.25*s,
                math.max(0, fw - 0.8*s),
                math.max(1, ih*0.30),
                0.4*s)
  end

  g.setColor(1,1,1,1)
end

local function directBattleGender(battle,sideName,side)
  local data=(battle and battle.data)
      or (battle and battle.game and battle.game.data)
      or {}
  local src=GoldCompat.sourceBattleState(battle)
  if src and src.game and src.game.data then data=src.game.data end

  local Mon=GoldCompat.engineModule("src.battle.gen2.Mon")

  local function resolve(mon)
    if type(mon)~="table" then return nil end
    local g=mon.gender
    if g=="male" or g=="female" then return g end

    local species=mon.species or mon.id
    local dvs=mon.dvs
    local def=species and data and data.pokemon and data.pokemon[species]
    if Mon and type(Mon.gender)=="function" and def and dvs then
      local ok,value=pcall(Mon.gender,def,dvs,{
        species=species,
        level=mon.level,
      })
      if ok and (value=="male" or value=="female") then return value end
    end
    return nil
  end

  -- Presentation facade first.
  local candidates={
    side,
    side and side.live,
    side and side.mon,
    side and side.active,
    side and side.current,
    side and side.pokemon,
  }

  -- Then inspect the real Gen 2 battle state. Different beta revisions have
  -- used both player/enemy keys and 1/2 slots for shownMon.
  if src then
    local idx=(sideName=="player") and 1 or 2
    local shown=src.shownMon
    candidates[#candidates+1]=type(shown)=="table" and shown[sideName] or nil
    candidates[#candidates+1]=type(shown)=="table" and shown[idx] or nil

    local core=src.battle
    local coreSide=core and core[sideName]
    candidates[#candidates+1]=coreSide
    candidates[#candidates+1]=coreSide and coreSide.mon
    candidates[#candidates+1]=coreSide and coreSide.active
    candidates[#candidates+1]=coreSide and coreSide.current
  end

  for _,candidate in ipairs(candidates) do
    local g=resolve(candidate)
    if g then return g end
  end
  return nil
end

local function battleNameWidth(text,size)
  local ok,w=pcall(function()
    local f=font((tonumber(size) or 4)*UI_TEXT_SCALE*GoldCompat.userTextScale())
    return f and f:getWidth(tostring(text or "")) or 0
  end)
  if ok and tonumber(w) then return w end
  return #tostring(text or "")*(tonumber(size) or 4)*0.55
end

local BATTLE_TYPE_COLORS={
  NORMAL={0.58,0.58,0.48,1},FIGHTING={0.72,0.20,0.16,1},
  FLYING={0.46,0.60,0.88,1},POISON={0.58,0.24,0.66,1},
  GROUND={0.73,0.55,0.24,1},ROCK={0.59,0.48,0.20,1},
  BUG={0.46,0.61,0.15,1},GHOST={0.36,0.29,0.58,1},
  STEEL={0.48,0.54,0.58,1},FIRE={0.89,0.29,0.12,1},
  WATER={0.20,0.48,0.82,1},GRASS={0.26,0.62,0.24,1},
  ELECTRIC={0.91,0.67,0.10,1},PSYCHIC={0.86,0.27,0.50,1},
  ICE={0.32,0.70,0.73,1},DRAGON={0.39,0.25,0.76,1},
  DARK={0.31,0.27,0.25,1},FAIRY={0.84,0.45,0.67,1},
}
local BATTLE_TYPE_SHORT={
  NORMAL="NO",FIGHTING="FT",FLYING="FY",POISON="PO",GROUND="GD",
  ROCK="RK",BUG="BG",GHOST="GH",STEEL="ST",FIRE="FR",WATER="WT",
  GRASS="GS",ELECTRIC="EL",PSYCHIC="PS",ICE="IC",DRAGON="DN",
  DARK="DK",FAIRY="FA",
}

local function normalizedBattleType(value)
  if type(value)=="table" then value=value.id or value.name or value.type end
  local TypeChart=GoldCompat.engineModule("src.battle.TypeChart")
  if TypeChart and type(TypeChart.displayName)=="function" then
    local okName,name=pcall(TypeChart.displayName,value)
    if okName and name then value=name end
  end
  local name=tostring(value or ""):upper():gsub("^TYPE_",""):gsub("[^A-Z]","")
  return name~="" and name or nil
end

local function battleTypeList(battle,battler)
  local mon=battler and (battler.mon or battler.live or battler)
  local types=type(mon)=="table" and mon.types or nil
  if type(types)~="table" or #types==0 then
    local species=type(mon)=="table" and mon.species
      or (battler and battler.species)
    local data=(battle and battle.data) or (battle and battle.game and battle.game.data)
    local def=data and data.pokemon and species and data.pokemon[species]
    types=def and def.types or nil
  end
  local out={}
  for i=1,math.min(2,type(types)=="table" and #types or 0) do
    local name=normalizedBattleType(types[i])
    if name then out[#out+1]=name end
  end
  return out
end

local function drawBattleTypeIndicators(battle,battler,x,y,s)
  local types=battleTypeList(battle,battler)
  if #types==0 then return false end
  local G=love.graphics
  local badgeW,badgeH,gap=7.8*s,6.2*s,0.7*s
  for i,name in ipairs(types) do
    local bx=x+(i-1)*(badgeW+gap)
    local color=BATTLE_TYPE_COLORS[name] or {0.34,0.40,0.42,1}
    G.setColor(0.12,0.14,0.14,0.92)
    roundedRect("fill",bx-0.6*s,y-0.6*s,badgeW+1.2*s,badgeH+1.2*s,1.8*s)
    G.setColor(color)
    roundedRect("fill",bx,y,badgeW,badgeH,1.4*s)
    printText(BATTLE_TYPE_SHORT[name] or name:sub(1,3),bx,y+0.25*s,
      2.15*s,{1,1,1,1},"center",badgeW)
  end
  G.setColor(1,1,1,1)
  return true
end

local function drawEnemyHUD(battle, s)
  if not enemyVisible(battle) then return end

  local margin=7*s
  local w,h=112*s,35*s
  local sw=love.graphics.getWidth()
  local iosTop=featureEnabled("iosTopBattleHUD")

  -- Corner layout: enemy always owns the upper-left edge. The toggle changes
  -- the player's plate placement, but never bunches the two HUDs together.
  local x=margin
  local y=margin
  -- Only pull the plate left if it would otherwise cross the screen middle
  -- (tiny windows); at normal size it stays in the upper-left corner.
  if x + w > sw/2 then x = math.max(8, sw/2 - w) end
  local b=battle.enemy

  -- Card + backplate restored; drawPlate's outer border is already disabled
  -- (borderless), so only the framed box shows without the orange ring.
  drawPlate(x,y,w,h,s)

  local textColor={0.11,0.12,0.11,1}
  local enemyName=displayName(b)
  printText(enemyName,x+7*s,y+2.0*s,6.4*s,textColor,"left",48*s)
  -- Status now sits right after the gender icon on the name row (classic
  -- "NAME ♂ PAR" placement) instead of stacked on its own row down by the
  -- numeric HP. statusAfterX is set only when a gender glyph was actually
  -- drawn, so status has a real anchor to sit to the right of.
  local statusAfterX=nil
  do
    -- presentBattleState already stamps the live Gen2 mon's gender onto this
    -- side facade. Keep the glyph in a fixed reserved slot between name/level
    -- so font measurement can never suppress it.
    local gender=b and b.gender
    if gender~="male" and gender~="female" then
      gender=directBattleGender(battle,"enemy",b)
    end
    if gender=="male" or gender=="female" then
      -- Sit immediately after the rendered Pokémon name, with a hard cap that
      -- leaves the Lv. field untouched.
      local nameX=x+7*s
      local nameW=battleNameWidth(enemyName,6.4*s)
      local gx=math.min(nameX+nameW+1.5*s, x+56*s)
      local gy=y+6.05*s
      local iconSize=math.max(9,math.min(12,3.0*s))
      GoldCompat.drawGenderIcon(gx,gy,iconSize,gender)
      statusAfterX=gx+iconSize+2.2*s
    end
  end
  drawBattleTypeIndicators(battle,b,x+61.5*s,y+4.15*s,s)
  printText("Lv."..tostring((b.mon and b.mon.level) or "?"),
            x+64*s,y+2.2*s,5.5*s,textColor,"right",39*s)

  drawStyledHP(x+7*s,y+14.5*s,97*s,7*s,b)

  -- Numeric HP readout inside the box, left-aligned to the HP bar start so it
  -- sits clear of the right edge of the plate.
  pcall(function()
    local hpText=tostring(shownHP(b)).." / "..tostring(maxHP(b))
    printText(hpText,x+8*s,y+21.8*s+1*s,4.4*s,textColor,"left",53*s)
  end)
  local status=statusText(battle,b)
  if status then
    local r,g,bb,aa=statusColor(status)
    local typeStartX=x+61.5*s
    local maxW=statusAfterX and math.max(0,typeStartX-statusAfterX-1.5*s)
    if statusAfterX and maxW>=10*s then
      printText(status,statusAfterX,y+2.4*s,3.6*s,{r,g,bb,aa},"left",maxW)
    else
      -- No gender glyph, or the name left no room next to it: fall back to
      -- the original spot rather than overlapping the type badges.
      printText(status,x+8*s,y+22.0*s,3.8*s,{r,g,bb,aa})
    end
  end
end

-- commandRect is always commandGeometry() -- the FIGHT/POKéMON/BAG/RUN
-- panel's footprint -- regardless of which bottom panel is actually showing
-- right now. That was fine as long as every bottom panel shared its height,
-- but the 4x1 move list (moveGeometry, ~300*u tall) is taller than the
-- command grid (~210*u tall) it replaces during battle.phase=="moveSelect".
-- Anchoring the plate to commandRect.y in that phase let the move list's
-- own top edge climb above the plate and cover its bottom half (confirmed by
-- user screenshot). Anchor to whichever panel is actually on screen instead;
-- the 2x2 grid layout matches commandRect's height exactly by construction
-- (see GoldCompat.moveGeometry), so this is a no-op for that layout and the
-- plate never moves for it.
local function bottomPanelAnchorY(battle, commandRect)
  if battle and battle.phase == "moveSelect" then
    local ok, move = pcall(GoldCompat.moveGeometry)
    if ok and move and move.y < commandRect.y then return move.y end
  end
  return commandRect.y
end

local function drawPlayerHUD(battle, s, commandRect)
  if not playerVisible(battle) then return end

  local sw=love.graphics.getWidth()
  local w,h=116*s,35*s
  local margin=7*s
  local iosTop=featureEnabled("iosTopBattleHUD")
  local x=sw-w-margin
  local y=iosTop and margin
    or (bottomPanelAnchorY(battle,commandRect)-h-6*s+2*s)
  -- Keep the plate in the right half (never cross the middle) and never let
  -- it run off the right screen edge at small windows.
  if x < sw/2 then x = sw/2 end
  if x + w > sw - 8 then x = math.max(sw/2, sw - w - 8) end
  local b=battle.player

  -- Core geometry first. These are intentionally not dependent on font rendering.
  drawPlate(x,y,w,h,s)
  drawStyledHP(x+8*s,y+13.8*s,101*s,7.2*s,b)

  -- EXP is a core HUD primitive now, not a decorative tail-end draw.
  -- It renders before any potentially failing status/number typography.
  GoldCompat.drawEXPRow(x, y, w, h, battle, b, s)

  local textColor={0.11,0.12,0.11,1}

  -- Name and level are independently protected.
  pcall(function()
    local playerName=displayName(b)
    printText(playerName,x+8*s,y+1.8*s,6.4*s,textColor,"left",48*s)
  end)

  -- Status now sits right after the gender icon on the name row (classic
  -- "NAME ♂ PAR" placement) instead of stacked on its own pill down by the
  -- numeric HP. statusAfterX is set only when a gender glyph was actually
  -- drawn, so status has a real anchor to sit to the right of.
  local statusAfterX=nil
  do
    local gender=b and b.gender
    if gender~="male" and gender~="female" then
      gender=directBattleGender(battle,"player",b)
    end
    if gender=="male" or gender=="female" then
      local playerName=displayName(b)
      local nameX=x+8*s
      local nameW=battleNameWidth(playerName,6.4*s)
      local gx=math.min(nameX+nameW+1.5*s, x+58*s)
      local gy=y+5.85*s
      local iconSize=math.max(9,math.min(12,3.0*s))
      GoldCompat.drawGenderIcon(gx,gy,iconSize,gender)
      statusAfterX=gx+iconSize+2.2*s
    end
  end
  drawBattleTypeIndicators(battle,b,x+62.5*s,y+4.0*s,s)
  pcall(function()
    printText("Lv."..tostring((b.mon and b.mon.level) or "?"),
              x+65*s,y+2.1*s,5.4*s,textColor,"right",41*s)
  end)

  -- Status cannot stop HP numbers or EXP.
  pcall(function()
    local status=statusText(battle,b)
    if status then
      local r,g,bb,aa=statusColor(status)
      local lg=love.graphics
      local typeStartX=x+62.5*s
      local maxW=statusAfterX and math.max(0,typeStartX-statusAfterX-1.5*s)
      if statusAfterX and maxW>=10*s then
        printText(status,statusAfterX,y+2.5*s,3.6*s,{r,g,bb,aa},"left",maxW)
      else
        -- No gender glyph, or the name left no room next to it: fall back to
        -- the original pill spot rather than overlapping the type badges.
        lg.setColor(r,g,bb,0.12)
        roundedRect("fill",x+8*s,y+22.2*s,25*s,7.0*s,2.4*s)
        printText(status,x+10*s,y+22.0*s,3.8*s,{r,g,bb,aa})
        lg.setColor(1,1,1,1)
      end
    end
  end)

  -- Numeric HP is also isolated.
  pcall(function()
    local hpText=tostring(shownHP(b)).." / "..tostring(maxHP(b))
    printText(hpText,x+55*s,y+21.8*s+1*s,4.4*s,textColor,"right",53*s)
  end)
end

-- -------------------------------------------------------------------------
-- Responsive command + dialogue panels
-- -------------------------------------------------------------------------

local function battleMenuScale()
  local sw,sh=love.graphics.getDimensions()
  local mobile=featureEnabled("mobileBattleUI")
  local boxScale=GoldCompat.userBoxScale()
  local cached=GoldCompat.battleMenuScaleCache
  if cached and cached.sw==sw and cached.sh==sh
      and cached.mobile==mobile and cached.boxScale==boxScale then
    return cached.scale
  end

  local raw=math.min(sw/1280,sh/720)
  local scale
  if raw <= 1.5 then
    scale=clamp(raw,0.60,1.18)
  else
    scale=clamp(1.18 + (raw-1.5)*0.75,1.18,2.30)
  end

  -- Optional mobile presentation affects ONLY our custom battle interface.
  -- Mobile screens need the HUD to consume LESS of the viewport, not more.
  -- Desktop/non-mobile behavior is unchanged when this is off.
  if mobile then
    local portrait = sh > sw
    scale=scale*(portrait and 0.72 or 0.82)
  end
  scale=scale*boxScale
  GoldCompat.battleMenuScaleCache={
    sw=sw,sh=sh,mobile=mobile,boxScale=boxScale,scale=scale,
  }
  return scale
end

local function commandGeometry()
  local sw, sh = love.graphics.getDimensions()
  local u = battleMenuScale()

  local mobile=featureEnabled("mobileBattleUI")
  local portrait=sh>sw
  local w = clamp((mobile and (portrait and 500 or 540) or 600)*u,
    mobile and 330 or 390, mobile and 920 or 1380)
  local h = clamp((mobile and (portrait and 175 or 185) or 210)*u,
    mobile and 118 or 145, mobile and 330 or 485)
  local margin = clamp((mobile and (portrait and 18 or 20) or 24)*u,
    mobile and 12 or 14, mobile and 34 or 56)

  local x = math.max(8, sw-w-margin + 2)
  local y = math.max(8, sh-h-margin)
  return { x=x, y=y, w=w, h=h, u=u }
end

function GoldCompat.dialogueGeometry()
  local sw, sh = love.graphics.getDimensions()

  -- Dialogue uses the same bottom footprint as the command panel but is wider.
  local mobile=featureEnabled("mobileBattleUI")
  local portrait=sh>sw
  local w
  local h
  local margin
  if mobile then
    -- Keep dialogue comfortably inside the usable mobile viewport.
    w=clamp(sw*(portrait and 0.88 or 0.50),280,portrait and 620 or 760)
    h=clamp(sh*(portrait and 0.105 or 0.095),76,125)
    margin=clamp(sw*0.018,12,24)
  else
    w=clamp(sw*0.58*0.90*0.94,650,1040*0.90*0.94)
    h=clamp(sh*0.118*1.13*1.10,96*1.08*1.08,128*1.13*1.10)
    margin=clamp(sw*0.018,20,36)
  end

  local widthScale,heightScale=GoldCompat.dialogueLayoutScale()
  w=math.min(sw-margin*2,w*widthScale)
  h=math.min(sh-margin*2,h*heightScale)
  return { x=margin, y=sh-h-margin, w=w, h=h }
end


local function drawPanelBase(rect)
  local g = love.graphics

  g.setColor(0.02,0.03,0.04,0.42)
  roundedRect("fill", rect.x+8, rect.y+10, rect.w, rect.h, 17)

  g.setColor(0.95,0.95,0.92,0.98)
  roundedRect("fill", rect.x, rect.y, rect.w, rect.h, 15)

  g.setLineWidth(2.5)
  g.setColor(0.18,0.21,0.25,0.95)
  roundedRect("line", rect.x+1.25, rect.y+1.25, rect.w-2.5, rect.h-2.5, 14)
end

local function drawCommandMenu(battle)
  if not (battle and battle.phase == "menu" and not battle.safari
      and not battle.demo) then return end

  local rect = commandGeometry()
  drawPanelBase(rect)

  local g = love.graphics
  local u = rect.u or battleMenuScale()
  local pad = 15*u
  local gap = 11*u
  local cellW = (rect.w-pad*2-gap)/2
  local cellH = (rect.h-pad*2-gap)/2

  -- Preserve engine semantics: 1 FIGHT, 2 PKMN, 3 ITEM, 4 RUN.
  local options = {
    {index=1, label="FIGHT",   col=0,row=0},
    {index=2, label="POKéMON", col=1,row=0},
    {index=3, label="BAG",     col=0,row=1},
    {index=4, label="RUN",     col=1,row=1},
  }

  for _, opt in ipairs(options) do
    local x = rect.x+pad+opt.col*(cellW+gap)
    local y = rect.y+pad+opt.row*(cellH+gap)
    local selected = battle.menuIndex == opt.index

    if selected then
      g.setColor(0.16,0.30,0.42,1)
      roundedRect("fill", x,y,cellW,cellH,10*u)
      g.setColor(0.95,0.36,0.17,1)
      roundedRect("fill", x+6*u,y+7*u,5*u,cellH-14*u,2*u)
      printText(opt.label, x+18*u, y+cellH*0.12, cellH*0.43,
                {0.98,0.98,0.96,1}, "center", cellW-28*u)
    else
      g.setColor(0.86,0.87,0.84,1)
      roundedRect("fill", x,y,cellW,cellH,10*u)
      g.setColor(0.97,0.97,0.95,1)
      roundedRect("fill", x+2*u,y+2*u,cellW-4*u,cellH-4*u,8*u)
      printText(opt.label, x+10*u, y+cellH*0.12, cellH*0.43,
                {0.12,0.14,0.16,1}, "center", cellW-20*u)
    end
  end
end

local function drawDialogue(battle)
  if not (battle and battle.phase == "messages") then return end
  if battle.__gen2 then
    if not battle.message or tostring(battle.message)=="" then return end
  elseif not (battle.current or battle.animPlaying or battle.msgHold
      or #(battle.shown or {}) > 0) then
    return
  end

  local rect = GoldCompat.dialogueGeometry()
  drawPanelBase(rect)

  local g = love.graphics
  local lines = messageLines(battle)
  local fullLines = GoldCompat.messagePageFullLines(battle)
  local textColor = {0.12,0.14,0.16,1}
  local pageComplete =
    battle.msgWaiting
    or battle.msgPrompt
    or battle.msgHold
    or (battle.current and battle.current.done)
  -- Reserve extra pixels for the 0.45px weight pass and raster rounding.
  -- Without this, a line that mathematically fits exactly can lose its last
  -- one or two glyphs at the right scissor edge.
  local contentW = math.max(1, rect.w-60)
  local preferred = clamp(rect.h*0.36,34,50)
  local minimum = math.max(18,preferred*0.62)

  -- Font metrics are chosen from the COMPLETE current page, not from the
  -- characters revealed so far. Typewriter progression therefore never
  -- changes font size or line spacing mid-message.
  local innerTop = 10
  local innerBottom = 22
  local innerH = math.max(1,rect.h-innerTop-innerBottom)

  local metricSource=(#fullLines>0 and fullLines or lines)
  local metricKey=tostring(battle.current and battle.current.text or "")
      .."|"..table.concat(metricSource,"\n")
      .."|"..tostring(pageComplete)
      .."|text="..tostring(optionValue("uiTextSize"))
      .."|weight="..tostring(optionValue("uiTextWeight"))
      .."|box="..tostring(optionValue("uiBoxScale"))
      .."|w="..tostring(math.floor(rect.w+0.5))
      .."|h="..tostring(math.floor(rect.h+0.5))

  if not battle.__gen3MetricCache
      or battle.__gen3MetricCache.key~=metricKey then
    local size,glyphH,lineH,blockH,wrapped

    -- Always size from the FINAL (wrapped) page so the typewriter never
    -- animates the font: text is pinned at its finished size from the first
    -- revealed glyph; only the revealed-character window changes.
    size,glyphH,lineH,blockH,wrapped=GoldCompat.fittedCompletedDialogue(
      metricSource,preferred,minimum,contentW,innerH)

    battle.__gen3MetricCache={
      key=metricKey,size=size,glyphH=glyphH,lineH=lineH,blockH=blockH,
      wrapped=wrapped,
    }
  end

  local metrics=battle.__gen3MetricCache
  local size,glyphH,lineH,blockH=
    metrics.size,metrics.glyphH,metrics.lineH,metrics.blockH

  if pageComplete and metrics.wrapped then
    lines=metrics.wrapped
  end
  local visible=math.min(2,#lines)

  local x = rect.x+24

  -- Fixed safe baselines. Dynamic vertical centering was vulnerable to
  -- fractional font-height rounding on some renderer/scaling combinations,
  -- which let line two touch or cross the bottom border.
  local firstY = rect.y + 13
  local secondY = rect.y + rect.h - glyphH - 18

  g.setScissor(
    math.floor(rect.x+18),
    math.floor(rect.y+8),
    math.floor(rect.w-36),
    math.floor(rect.h-18)
  )

  if visible >= 1 then
    printText(lines[1],x,firstY,size,textColor,"left",contentW)
  end
  if visible >= 2 then
    printText(lines[2],x,secondY,size,textColor,"left",contentW)
  end

  g.setScissor()

  if (battle.msgWaiting or battle.msgPrompt)
      and battle.frame % 60 < 30 then
    -- clean modern continue marker
    local g = love.graphics
    g.setColor(0.20,0.31,0.42,1)
    local cx = rect.x+rect.w-31
    local cy = rect.y+rect.h-22
    g.polygon("fill", cx,cy, cx+13,cy, cx+6.5,cy+9)
  end
end


-- -------------------------------------------------------------------------
-- Modern move selection
-- -------------------------------------------------------------------------

function GoldCompat.battleMoveLayout()
  local cached=GoldCompat.derivedOptionCache.battleMoveLayout
  if cached~=nil then return cached end
  local v=tostring(optionValue("battleMoveLayout") or "list")
  local value=(v=="grid") and "grid" or "list"
  GoldCompat.derivedOptionCache.battleMoveLayout=value
  return value
end

function GoldCompat.moveGeometry()
  local sw, sh = love.graphics.getDimensions()
  local u = battleMenuScale()

  local mobile=featureEnabled("mobileBattleUI")
  local portrait=sh>sw
  local grid = GoldCompat.battleMoveLayout()=="grid"

  local w = clamp((mobile and (portrait and 570 or 630) or 756)*u,
    mobile and 300 or 400, mobile and 1080 or 1660)

  local h
  if grid then
    -- The 2x2 layout deliberately reuses commandGeometry's exact base height
    -- and clamp range so its footprint is identical to the FIGHT/POKéMON/
    -- BAG/RUN panel it replaces. That means the player's HP plate (which
    -- rests just above whichever bottom panel is showing) never has to move
    -- for this layout -- unlike the taller 4x1 list below, which needs the
    -- plate nudged up (handled in drawPlayerHUD via bottomPanelAnchorY).
    local baseH = mobile and (portrait and 175 or 185) or 210
    h = clamp(baseH*u, mobile and 118 or 145, mobile and 330 or 485)
  else
    h = clamp((mobile and (portrait and 235 or 255) or 300)*u,
      mobile and 160 or 215, mobile and 455 or 690)
  end

  local margin = clamp((mobile and (portrait and 18 or 20) or 24)*u,
    mobile and 12 or 14, mobile and 36 or 56)

  -- Keep the menu fully on-screen at any window size: it scales down with the
  -- viewport instead of overflowing off the left/bottom edge.
  local x = math.max(8, sw - w - margin + 2)
  local y = math.max(8, sh - h - margin)
  return {
    x = x,
    y = y,
    w = w,
    h = h,
    u = u,
    grid = grid,
  }
end

function GoldCompat.moveTypeName(def)
  if not def then return "—" end
  local t = def.type or def.moveType or def.damageType
  if type(t) == "table" then
    t = t.name or t.id
  end
  return t and tostring(t):upper() or "—"
end

local function moveMaxPP(def, mv)
  if mv and (mv.maxPP or mv.maxPp) then return mv.maxPP or mv.maxPp end
  if def and def.pp then return def.pp end
  return mv and mv.pp or 0
end

-- 2x2 MOVE MENU LAYOUT. Cell (i) sits at col=(i-1)%2, row=floor((i-1)/2) --
-- deliberately matching WideBattle.moveGridIndex's own row/col math
-- (src/battle/WideBattle.lua) exactly, since that same math also runs
-- natively when the "battle.move_grid_navigation" hook this mod registers
-- returns true for this layout: pressing left/right/up/down needs to land on
-- the visually adjacent cell, not just whatever cell native's own vertical
-- list order would have picked.
local function drawMoveSelectGrid(battle, rect)
  local moves = battle.player.curMoves
  local u = rect.u or battleMenuScale()
  local pad = 14*u
  local gap = 8*u
  local infoH = 40*u
  local gridTop = rect.y + pad
  local gridBottom = rect.y + rect.h - pad - infoH - 6*u
  local cellW = (rect.w - pad*2 - gap) / 2
  local cellH = (gridBottom - gridTop - gap) / 2

  local g = love.graphics

  for i = 1, 4 do
    local mv = moves[i]
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    local x = rect.x + pad + col * (cellW + gap)
    local y = gridTop + row * (cellH + gap)
    local selected = battle.moveIndex == i
    local disabled = battle.player.disabledSlot == i
    local marked = battle.moveSwapIndex == i

    if selected then
      g.setColor(0.16, 0.30, 0.42, 1)
      roundedRect("fill", x, y, cellW, cellH, 9*u)
      g.setColor(0.95, 0.36, 0.17, 1)
      roundedRect("fill", x + 6*u, y + 6*u, 5*u, cellH - 12*u, 2*u)
    else
      g.setColor(0.86, 0.87, 0.84, 1)
      roundedRect("fill", x, y, cellW, cellH, 9*u)
      g.setColor(0.97, 0.97, 0.95, 1)
      roundedRect("fill", x + 2*u, y + 2*u, cellW - 4*u, cellH - 4*u, 7*u)
    end

    if mv then
      local def = battle.data.moves[mv.id]
      local label = def and def.name or tostring(mv.id)
      local curPP = mv.pp or 0
      local maxPP = moveMaxPP(def, mv)

      local textColor = selected and {0.98,0.98,0.96,1}
                                  or {0.12,0.14,0.16,1}
      if disabled then
        textColor = selected and {1.00,0.78,0.72,1}
                             or {0.62,0.30,0.26,1}
      end

      local nameSize = clamp(cellH * 0.30, 13*u, 26*u)
      printText(label, x + 16*u, y + cellH*0.14, nameSize, textColor,
                "left", cellW - 26*u)

      local ppText = ("%d / %d"):format(curPP, maxPP)
      printText(ppText, x + 14*u, y + cellH - cellH*0.34,
                clamp(cellH*0.22, 10*u, 20*u), textColor, "left", cellW-26*u)

      if marked then
        printText("MOVE", x + cellW - 48*u, y + 6*u,
                  clamp(cellH*0.18, 9*u, 16*u),
                  selected and {0.98,0.84,0.34,1} or {0.64,0.46,0.08,1},
                  "right", 42*u)
      end
    else
      printText("—", x + 16*u, y + cellH*0.14,
                clamp(cellH*0.28, 12*u, 22*u),
                selected and {0.98,0.98,0.96,0.5}
                         or {0.35,0.36,0.37,0.55})
    end
  end

  local selectedMove = moves[battle.moveIndex]
  if selectedMove then
    local def = battle.data.moves[selectedMove.id]
    local typeText = "TYPE  " .. GoldCompat.moveTypeName(def)
    local ppText = ("PP  %d / %d"):format(
      selectedMove.pp or 0, moveMaxPP(def, selectedMove))

    local infoY = rect.y + rect.h - pad - infoH
    g.setColor(0.90,0.91,0.89,1)
    roundedRect("fill", rect.x + pad, infoY, rect.w - pad*2, infoH, 8*u)

    printText(typeText, rect.x + pad + 14*u, infoY + 6*u,
              19*u, {0.20,0.22,0.24,1})
    printText(ppText, rect.x + rect.w - pad - 170*u, infoY + 6*u,
              19*u, {0.20,0.22,0.24,1}, "right", 155*u)

    if battle.player.disabledSlot == battle.moveIndex then
      printText("DISABLED", rect.x + rect.w/2 - 54*u, infoY + 8*u,
                14*u, {0.70,0.20,0.16,1}, "center", 108*u)
    elseif selectedMove.pp <= 0 then
      printText("NO PP", rect.x + rect.w/2 - 46*u, infoY + 8*u,
                14*u, {0.70,0.20,0.16,1}, "center", 92*u)
    end
  end
end

local function drawMoveSelect(battle)
  if not (battle and battle.phase == "moveSelect"
      and battle.player and battle.player.curMoves) then
    return
  end

  local rect = GoldCompat.moveGeometry()
  drawPanelBase(rect)

  if rect.grid then
    return drawMoveSelectGrid(battle, rect)
  end

  local moves = battle.player.curMoves
  local u = rect.u or battleMenuScale()
  local pad = 16*u
  local gap = 8*u
  local infoH = 50*u
  local listTop = rect.y + pad
  local listBottom = rect.y + rect.h - pad - infoH - 7*u
  local rowH = (listBottom - listTop - gap * 3) / 4

  local g = love.graphics

  for i = 1, 4 do
    local mv = moves[i]
    local y = listTop + (i - 1) * (rowH + gap)
    local selected = battle.moveIndex == i
    local disabled = battle.player.disabledSlot == i
    local marked = battle.moveSwapIndex == i

    if selected then
      g.setColor(0.16, 0.30, 0.42, 1)
      roundedRect("fill", rect.x + pad, y, rect.w - pad*2, rowH, 9*u)
      g.setColor(0.95, 0.36, 0.17, 1)
      roundedRect("fill", rect.x + pad + 6*u, y + 6*u, 5*u, rowH - 12*u, 2*u)
    else
      g.setColor(0.86, 0.87, 0.84, 1)
      roundedRect("fill", rect.x + pad, y, rect.w - pad*2, rowH, 9)
      g.setColor(0.97, 0.97, 0.95, 1)
      roundedRect("fill", rect.x + pad + 2*u, y + 2*u,
                  rect.w - pad*2 - 4*u, rowH - 4*u, 7*u)
    end

    if mv then
      local def = battle.data.moves[mv.id]
      local label = def and def.name or tostring(mv.id)
      local curPP = mv.pp or 0
      local maxPP = moveMaxPP(def, mv)

      local textColor = selected and {0.98,0.98,0.96,1}
                                  or {0.12,0.14,0.16,1}
      if disabled then
        textColor = selected and {1.00,0.78,0.72,1}
                             or {0.62,0.30,0.26,1}
      end

      local nameSize = clamp(rowH * 0.40, 16*u, 34*u)
      printText(label, rect.x + pad + 18*u, y + rowH*0.13,
                nameSize, textColor)

      local ppText = ("%d / %d"):format(curPP, maxPP)
      printText(ppText, rect.x + rect.w - pad - 138*u, y + rowH*0.15,
                clamp(rowH*0.30, 13*u, 26*u), textColor, "right", 126*u)

      if marked then
        printText("MOVE", rect.x + rect.w - pad - 215*u, y + rowH*0.17,
                  clamp(rowH*0.25, 11*u, 21*u),
                  selected and {0.98,0.84,0.34,1} or {0.64,0.46,0.08,1})
      end
    else
      printText("—", rect.x + pad + 18*u, y + rowH*0.13,
                clamp(rowH*0.34, 14*u, 28*u),
                selected and {0.98,0.98,0.96,0.5}
                         or {0.35,0.36,0.37,0.55})
    end
  end

  local selectedMove = moves[battle.moveIndex]
  if selectedMove then
    local def = battle.data.moves[selectedMove.id]
    local typeText = "TYPE  " .. GoldCompat.moveTypeName(def)
    local ppText = ("PP  %d / %d"):format(
      selectedMove.pp or 0, moveMaxPP(def, selectedMove))

    local infoY = rect.y + rect.h - pad - infoH
    g.setColor(0.90,0.91,0.89,1)
    roundedRect("fill", rect.x + pad, infoY, rect.w - pad*2, infoH, 9*u)

    printText(typeText, rect.x + pad + 16*u, infoY + 7*u,
              23*u, {0.20,0.22,0.24,1})
    printText(ppText, rect.x + rect.w - pad - 190*u, infoY + 7*u,
              23*u, {0.20,0.22,0.24,1}, "right", 175*u)

    if battle.player.disabledSlot == battle.moveIndex then
      printText("DISABLED", rect.x + rect.w/2 - 62*u, infoY + 10*u,
                17*u, {0.70,0.20,0.16,1}, "center", 124*u)
    elseif selectedMove.pp <= 0 then
      printText("NO PP", rect.x + rect.w/2 - 54*u, infoY + 10*u,
                17*u, {0.70,0.20,0.16,1}, "center", 108*u)
    end
  end
end


-- -------------------------------------------------------------------------
-- Cohesive overworld UI alpha
-- -------------------------------------------------------------------------


-- Same Plain Pixel source as the battle HUD, but sized for the native 160x144
-- menu canvas so overworld UI and battle UI read as one continuous system.
function GoldCompat.owFont(size)
  size = math.max(7, math.floor(size + 0.5))
  if overworldFonts[size] then return overworldFonts[size] end
  local ok, f = pcall(love.graphics.newFont,
    EngineFont.PLAINPIXEL, size, "normal")
  if not ok or not f then
    local fallback = love.graphics.getFont()
    overworldFonts[size] = fallback
    return fallback
  end
  if f.setFilter then pcall(f.setFilter, f, "nearest", "nearest") end
  overworldFonts[size] = f
  return f
end

function GoldCompat.owText(text, x, y, size, color, align, width)
  local g = love.graphics
  local f = GoldCompat.owFont(size)
  local old = g.getFont()
  g.setFont(f)

  text = tostring(text or "")
  color = color or {0.08,0.08,0.08,1}

  -- Integer-aligned, single-pass text for maximum menu clarity.
  x = math.floor(x + 0.5)
  y = math.floor(y + 0.5)

  if width then
    g.setColor(color)
    g.printf(text, x, y, math.floor(width + 0.5), align or "left")
  else
    g.setColor(color)
    g.print(text, x, y)
  end

  if old then g.setFont(old) end
  g.setColor(1,1,1,1)
end


local function owStatus(mon)
  if (mon.hp or 0) <= 0 then return "FNT" end
  if mon.status then return tostring(mon.status):upper() end
  return nil
end


-- Restrained FireRed/LeafGreen-style overworld panel.
-- Unlike the battle HUD, START/Bag intentionally avoid heavy beveling/cards.
function GoldCompat.frlgMenuPanel(x, y, w, h)
  local g = love.graphics

  -- Tiny shadow, then green/olive edge, then warm white face.
  g.setColor(0.10,0.16,0.13,0.45)
  g.rectangle("fill", x+2, y+2, w, h)

  g.setColor(0.20,0.20,0.18,1)
  g.rectangle("fill", x, y, w, h)

  g.setColor(0.985,0.982,0.95,1)
  g.rectangle("fill", x+2, y+2, w-4, h-4)

  -- Light inner line gives the flat GBA panel a little HD definition.
  g.setColor(1.0,0.995,0.96,1)
  g.rectangle("line", x+3, y+3, w-6, h-6)

  g.setColor(1,1,1,1)
end

function GoldCompat.frlgSelection(x, y, w, h)
  local g = love.graphics
  -- FRLG-style restrained selection: charcoal field, white text.
  g.setColor(0.13,0.13,0.12,1)
  g.rectangle("fill", x, y, w, h)

  -- Thin light edge instead of a colored accent stripe.
  g.setColor(0.86,0.86,0.82,1)
  g.rectangle("line", x+0.5, y+0.5, w-1, h-1)

  g.setColor(1,1,1,1)
end

local martUIPatched=false

local function installMartUI()
  if martUIPatched then return end
  martUIPatched=true

  -- Quantity selection remains native input/update logic; only presentation
  -- is deferred to the final Mart renderer.
  local originalQuantityDraw=QuantityBox.draw
  QuantityBox.draw=function(self)
    local shop=shopStateInStack(self.game)
    if featureEnabled("revampedPokeMartUI")
        and shop and shop.__gen3uiShopList then
      self.__gen3uiShopQuantity=true
      State.activeShopQuantity=self
      return
    end
    if State.activeShopQuantity==self then State.activeShopQuantity=nil end
    return originalQuantityDraw(self)
  end
end


local GEN1_BAG_POCKETS={
  {id="ITEM",label="ITEMS"},
  {id="BALL",label="BALLS"},
  {id="KEY_ITEM",label="KEY"},
  {id="TM_HM",label="TM/HM"},
}

local function gen1BagPocketFor(game,id)
  local def=game and game.data and game.data.items and game.data.items[id]
  if def and def.machine then return "TM_HM" end
  local okBall,isBall=pcall(ItemEffects.isBall,id)
  if okBall and isBall then return "BALL" end
  if def and def.keyItem then return "KEY_ITEM" end
  return "ITEM"
end

local function gen1BagRowsForPocket(list,pocketId)
  local game=list and list.game
  local save=game and game.save
  local rows={}
  if not (game and save) then return rows end

  for _,id in ipairs(BagInventory.order(save) or {}) do
    local count=save.inventory and save.inventory[id]
    if count and count>0 and gen1BagPocketFor(game,id)==pocketId then
      local def=game.data.items and game.data.items[id]
      rows[#rows+1]={
        value=id,
        label=(def and def.name) or id,
        right="x"..tostring(count),
      }
    end
  end
  return rows
end

local function gen1BagRefresh(list,preserveId)
  if not list then return end
  local pocket=GEN1_BAG_POCKETS[list.__gen3uiBagPocketIndex or 1]
      or GEN1_BAG_POCKETS[1]
  local rows=gen1BagRowsForPocket(list,pocket.id)

  -- IMPORTANT: never replace list.items here. BagMenu/ListMenu owns that flat
  -- native array and several native item actions/reorder paths expect its
  -- indices to match Bag.order(). The categorized UI gets a parallel view.
  list.__gen3uiBagViewRows=rows

  local oldIndex=list.__gen3uiBagViewIndex or 1
  local nextIndex=nil
  if preserveId then
    for i,row in ipairs(rows) do
      if row.value==preserveId then
        nextIndex=i
        break
      end
    end
  end

  if #rows==0 then
    list.__gen3uiBagViewIndex=1
    list.__gen3uiBagViewScroll=0
    return
  end

  local index=nextIndex or math.max(1,math.min(oldIndex,#rows))
  -- Match GoldCompat.drawGoldPack's actual row capacity (embedded=false for
  -- the Gen 1 categorized bag view) so keyboard scrolling never disagrees
  -- with what is drawn, at any TEXT SIZE setting.
  local visible=GoldCompat.bagPackVisibleRows(false)
  local scroll=math.max(0,math.min(
    list.__gen3uiBagViewScroll or 0,
    math.max(0,#rows-visible)))

  if index-scroll<1 then
    scroll=index-1
  elseif index-scroll>visible then
    scroll=index-visible
  end

  list.__gen3uiBagViewIndex=index
  list.__gen3uiBagViewScroll=math.max(0,
    math.min(scroll,math.max(0,#rows-visible)))
end

local function gen1BagViewSelected(list)
  local rows=list and list.__gen3uiBagViewRows or nil
  if not rows then return nil end
  return rows[list.__gen3uiBagViewIndex or 1]
end

local function gen1BagNativeIndexForId(list,id)
  if not (list and id) then return nil end
  for i,row in ipairs(list.items or {}) do
    if row and row.value==id then return i end
  end
  return nil
end

local function gen1BagMoveView(list,delta)
  local rows=list.__gen3uiBagViewRows or {}
  local count=#rows
  if count==0 then return false end

  local oldIndex=list.__gen3uiBagViewIndex or 1
  local index=oldIndex+delta
  -- Gen 1's normal ListMenu does not wrap unless explicitly enabled.
  index=math.max(1,math.min(count,index))
  if index==oldIndex then return false end
  list.__gen3uiBagViewIndex=index

  local visible=GoldCompat.bagPackVisibleRows(false)
  local scroll=list.__gen3uiBagViewScroll or 0
  if index-scroll<1 then
    scroll=index-1
  elseif index-scroll>visible then
    scroll=index-visible
  end
  list.__gen3uiBagViewScroll=math.max(0,
    math.min(scroll,math.max(0,count-visible)))
  return true
end

local function gen1BagDescription(list)
  local row=gen1BagViewSelected(list)
  if not row then return "Choose an item." end
  local game=list.game
  local def=game and game.data and game.data.items and game.data.items[row.value]
  if def and def.machine then
    local move=game.data.moves and game.data.moves[def.machine.move]
    return "Teaches "..tostring((move and move.name) or def.machine.move or "a move").."."
  end
  if def and (def.description or def.desc) then
    return tostring(def.description or def.desc)
  end
  local pocket=gen1BagPocketFor(game,row.value)
  if pocket=="BALL" then return "Used to catch wild POKéMON." end
  if pocket=="KEY_ITEM" then return "An important KEY ITEM." end
  return "Choose an item."
end

-- Dedicated Gen 1 categorized-Bag TM/HM path.
function GoldCompat.gen1BagUseMachine(list,id)
  local game=list and list.game
  local def=game and game.data and game.data.items and game.data.items[id]
  if not (game and def and def.machine) then return false end

  local TextBox=require("src.render.TextBox")
  local Screens=require("src.ui.Screens")
  local Strings=require("src.core.Strings")
  local moveDef=game.data.moves and game.data.moves[def.machine.move]
  local moveName=(moveDef and moveDef.name) or def.machine.move
  local booted=def.machine.kind=="HM"
      and "Booted up an HM!" or Strings("Booted up a TM!")

  local function showMessages(msgs,onDone)
    if not msgs or #msgs==0 then
      if onDone then onDone() end
      return
    end
    game.stack:push(TextBox.new(game,table.concat(msgs,"\f"),onDone))
  end

  local function teachTo(mon)
    local result,payload=ItemEffects.use(
      game.data,game.save,id,mon,nil,nil,game.overworld)

    if result~="learn" and result~="learnkept" then
      showMessages(payload)
      return
    end

    local taughtMove=payload
    local taughtDef=game.data.moves[taughtMove]
    local function markTaught()
      pcall(function()
        require("src.world.PikachuFollower")
          .modifyHappiness(game.save,"USEDTMHM",mon)
      end)
    end
    local function consumeTM()
      if result=="learn" then BagInventory.remove(game.save,id,1) end
    end

    list:close()

    if #mon.moves<4 then
      table.insert(mon.moves,{id=taughtMove,pp=taughtDef.pp})
      consumeTM()
      markTaught()
      local monDef=game.data.pokemon[mon.species]
      showMessages({
        Strings("%s learned\n%s!",
          mon.nickname or (monDef and monDef.name) or mon.species,
          taughtDef.name)
      })
    else
      Screens.push(game,"MoveLearnMenu",mon,taughtMove,function(learned)
        if learned then
          consumeTM()
          markTaught()
        end
      end)
    end
  end

  -- CONFIRMED against the real src/ui/BagMenu.lua pickTargetAndUse: the
  -- native TM/HM party picker also passes itemUse=true, battle=<the active
  -- battle, nil here since this path is overworld-only>, and
  -- keepOpen=true whenever def.machine~=nil and there's no battle (its
  -- comment: "TM/HM stays up through predef LearnMove"). This
  -- reimplementation omitted all three, which could leave the picker
  -- behaving like a generic party-switch menu instead of the native
  -- item-teach flow in edge cases (e.g. what closes/reopens it on a
  -- refusal). Matching the real opts shape here costs nothing and removes
  -- one more guessed field set from this flow.
  showMessages({booted,Strings("It contained\n%s!",moveName)},function()
    Screens.push(game,"PartyMenu",{
      pickOnly=true,
      itemUse=true,
      battle=nil,
      keepOpen=true,
      tmhm={move=def.machine.move,kind=def.machine.kind},
      onSwitch=function(mon) teachTo(mon) end,
    })
  end)
  return true
end

local function gen1BagGoldAdapter(list)
  local pocketIndex=list.__gen3uiBagPocketIndex or 1
  local pocket=GEN1_BAG_POCKETS[pocketIndex] or GEN1_BAG_POCKETS[1]
  local adapter={
    index=list.__gen3uiBagViewIndex or 1,
    scroll=list.__gen3uiBagViewScroll or 0,
    rows={},
    -- FOUND: this used to hardcode 6, but GoldCompat.drawGoldPack prefers
    -- pack.visibleRows over its own dynamic GoldCompat.bagPackVisibleRows()
    -- fallback whenever it's set (tonumber(pack.visibleRows) or ...) -- so a
    -- fixed 6 here silently overrode the real, text-size-aware row count for
    -- every Gen 1 Bag render. gen1BagRefresh/gen1BagMoveView (the input/
    -- scroll trackers right above this function) already correctly call
    -- GoldCompat.bagPackVisibleRows(false) themselves, so at any TEXT SIZE
    -- other than default the drawn window (fixed at 6) and the scrolled
    -- window (dynamic, can be smaller) disagreed -- reintroducing exactly the
    -- row-height/description-strip overlap bug already fixed for Gen 2, and
    -- compounding the Bag scroll-clamp fix shipped this same round, which
    -- depends on the drawn visible count actually matching reality. Leaving
    -- this unset lets drawGoldPack fall through to the same dynamic call
    -- Gen 2's real native PackMenu already relies on (it never sets
    -- .visibleRows at all).
  }
  function adapter:pocket() return pocket end
  function adapter:description() return gen1BagDescription(list) end

  for _,row in ipairs(list.__gen3uiBagViewRows or {}) do
    local def=list.game.data.items and list.game.data.items[row.value]
    local count=list.game.save.inventory
      and list.game.save.inventory[row.value] or 1
    local out={
      id=row.value,
      name=row.label or row.value,
      count=count,
      showCount=true,
    }

    if def and def.machine then
      -- Shared Gen 1 / Gen 2 presentation: always show the move taught.
      local move=list.game.data.moves and list.game.data.moves[def.machine.move]
      out.teaches=(move and move.name) or def.machine.move
      out.showCount=false
    end

    adapter.rows[#adapter.rows+1]=out
  end
  return adapter
end

-- ---------------------------------------------------------------------
-- Gen 1 Mart SELL: reuse the same categorized-pocket system already built
-- for the Bag (GEN1_BAG_POCKETS/gen1BagPocketFor) instead of the flat list
-- drawShopListFinal has always rendered for both BUY and SELL. Confirmed
-- directly by the user: "our bag ui already has built in categories in
-- gen 1. The only item menu that doesn't have this is the pokemart ui" --
-- the categorization model itself (which pocket an item id belongs to)
-- needs no new work at all, only a SELL-specific adapter, because unlike
-- the Bag (which owns a live game.save.inventory reference), this list is
-- a flat one-shot ListMenu built once by the real sellItems(game)
-- (src/ui/ShopMenu.lua) with no live inventory/Bag object of its own --
-- and its onChoose/onSelectKey/removeCurrent are all REAL GAME LOGIC that
-- read/mutate list.items[list.index] directly (removeCurrent is literally
-- `table.remove(self.items,self.index)` -- confirmed against the real
-- src/ui/ListMenu.lua), so exactly like the Bag wrap's syncNativeSelection,
-- list.index must be pointed at the categorized view's selected native
-- entry before ever calling into them, or a sale would consume/mutate the
-- wrong row.
-- ---------------------------------------------------------------------

local function gen1ShopSellRowsForPocket(list,pocketId)
  local game=list and list.game
  local rows={}
  if not game then return rows end
  -- Filter list.items itself (never copy/rebuild it) so every row here is
  -- the SAME table the real onChoose/removeCurrent will read and mutate.
  for _,item in ipairs(list.items or {}) do
    if item and not item.cancel
        and gen1BagPocketFor(game,item.value)==pocketId then
      rows[#rows+1]=item
    end
  end
  return rows
end

local function gen1ShopSellCancelItem(list)
  for _,item in ipairs(list and list.items or {}) do
    if item and item.cancel then return item end
  end
  return nil
end

local function gen1ShopSellRefresh(list,preserveId)
  if not list then return end
  local pocket=GEN1_BAG_POCKETS[list.__gen3uiShopSellPocketIndex or 1]
      or GEN1_BAG_POCKETS[1]
  local rows=gen1ShopSellRowsForPocket(list,pocket.id)
  list.__gen3uiShopSellViewRows=rows

  -- +1 slot: CANCEL is always selectable as the last row, exactly like the
  -- real flat SELL list's own trailing {cancel=true} entry.
  local total=#rows+1
  local oldIndex=list.__gen3uiShopSellViewIndex or 1
  local nextIndex=nil
  if preserveId then
    for i,row in ipairs(rows) do
      if row.value==preserveId then nextIndex=i break end
    end
  end

  local index=nextIndex or math.max(1,math.min(oldIndex,total))
  local visible=GoldCompat.shopSellVisibleRows()
  local scroll=math.max(0,math.min(
    list.__gen3uiShopSellViewScroll or 0,math.max(0,total-visible)))

  if index-scroll<1 then
    scroll=index-1
  elseif index-scroll>visible then
    scroll=index-visible
  end

  list.__gen3uiShopSellViewIndex=index
  list.__gen3uiShopSellViewScroll=math.max(0,
    math.min(scroll,math.max(0,total-visible)))
end

local function gen1ShopSellViewSelected(list)
  local rows=list and list.__gen3uiShopSellViewRows
  if not rows then return nil end
  local index=list.__gen3uiShopSellViewIndex or 1
  if index<=#rows then return rows[index] end
  return gen1ShopSellCancelItem(list)
end

local function gen1ShopSellMoveView(list,delta)
  local rows=list.__gen3uiShopSellViewRows or {}
  local total=#rows+1
  local oldIndex=list.__gen3uiShopSellViewIndex or 1
  local index=math.max(1,math.min(total,oldIndex+delta))
  if index==oldIndex then return false end
  list.__gen3uiShopSellViewIndex=index

  local visible=GoldCompat.shopSellVisibleRows()
  local scroll=list.__gen3uiShopSellViewScroll or 0
  if index-scroll<1 then
    scroll=index-1
  elseif index-scroll>visible then
    scroll=index-visible
  end
  list.__gen3uiShopSellViewScroll=math.max(0,
    math.min(scroll,math.max(0,total-visible)))
  return true
end

local function gen1ShopSellBeep(list)
  -- Mirrors the real ListMenu.lua local beep(self) exactly (same guard,
  -- same sound key) since this wrap fully replaces list.update and so
  -- never runs through native beep() itself for the actions below.
  if list.noSound or not (list.game and list.game.data) then return end
  pcall(function()
    require("src.core.Sound").play(list.game.data,"Press_AB")
  end)
end

local function installOverworldUI(mod)
  if overworldUIPatched then return end
  overworldUIPatched = true

  -- Mark only the real START menu instance. Menu is generic and used in many
  -- places; the custom renderer branches exclusively on this marker.
  local originalStartNew = StartMenu.new
  StartMenu.new = function(game)
    local menu = originalStartNew(game)
    menu.__gen3uiStart = true

    -- The UI settings panel is an in-place mode of the real START menu.
    -- This guarantees the overworld remains beneath it and avoids a second
    -- state / generic options renderer entirely.
    local normalItems=menu.items
    local normalMaxVisible=menu.maxVisible
    local normalRowStep=menu.rowStep
    local normalIndex=menu.index
    local normalScroll=menu.scroll
    local baseUpdate=menu.update

    local function enterUISettings()
      menu.__gen3uiUISettings=true
      menu.items={}
      for _,row in ipairs(DexUI.uiRows) do
        local captured=row
        menu.items[#menu.items+1]={
          label=captured.label,
          keepOpen=true,
          __gen3uiUIRow=captured,
          onSelect=function()
            DexUI.activateUIRow(game,captured)
          end,
        }
      end
      menu.index=1
      menu.scroll=0
      menu.rowStep=1
      menu.maxVisible=8
      menu:clampScroll()
    end

    local function leaveUISettings()
      menu.__gen3uiUISettings=nil
      menu.items=normalItems
      menu.rowStep=normalRowStep
      menu.maxVisible=normalMaxVisible
      menu.index=math.max(1,math.min(normalIndex or 1,#normalItems))
      menu.scroll=normalScroll or 0
      menu:clampScroll()
    end

    -- The hook-created UI row is already in normalItems. Mark it keepOpen so
    -- Menu:update does not pop START before its action switches presentation.
    for _,entry in ipairs(normalItems) do
      if entry.__gen3uiUIEntry or tostring(entry.label or ""):upper()=="UI" then
        entry.keepOpen=true
        entry.onSelect=enterUISettings
        entry.__gen3uiUIEntry=true
      end
    end

    menu.update=function(self,dt)
      if self.__gen3uiUISettings then
        local input=game.input
        if input and (input:wasPressed("b") or input:wasPressed("start")) then
          if input:wasPressed("b") then
            pcall(function()
              require("src.core.Sound").play(game.data,"Press_AB")
            end)
          end
          leaveUISettings()
          return
        end

        -- A/Up/Down remain native Menu behavior. Every settings row is
        -- keepOpen, so selecting a toggle updates it without closing START.
        baseUpdate(self,dt)
        return
      end

      baseUpdate(self,dt)
      normalIndex=self.index
      normalScroll=self.scroll
    end

    return menu
  end

  local originalMenuDraw = Menu.draw
  Menu.draw = function(self)
    if self.__gen3uiPokedexAction and featureEnabled("revampedPokedex")
        and not self.__gen3uiPokedexActionRenderFailed then
      DexUI.action=self
      return
    end

    if self.__gen3uiBagAction
        and (featureEnabled("revampedOverworldMenus")
          or GoldCompat.strictBattleUiForGame(self.game)) then
      State.activeBagActionMenu=self
      return
    end

    if self.__gen3uiStart then
      if not featureEnabled("revampedOverworldMenus") then
        State.activeStartMenu = nil
        return originalMenuDraw(self)
      end
      State.activeStartMenu = self
      return
    end

    if featureEnabled("revampedPokeMartUI")
        and self.__gen3uiShopMain
        and not self.__gen3uiMartRenderFailed then
      State.activeShopMenu=self
      return
    elseif self.__gen3uiShopMain and self.__gen3uiMartRenderFailed then
      return originalMenuDraw(self)
    end

    if featureEnabled("revampedPokemonPC") then
      if self.__gen3uiPCAccess then
        State.activePCAccessMenu=self
        State.activePCMenu=nil
        State.activePCActionMenu=nil
        return
      elseif self.__gen3uiPCMain then
        State.activePCMenu=self
        State.activePCAccessMenu=nil
        State.activePCActionMenu=nil
        return
      elseif self.__gen3uiPCAction then
        State.activePCActionMenu=self
        return
      end
    end

    -- Generic Menu is also used for Bag item actions such as USE / TOSS.
    if featureEnabled("revampedOverworldMenus")
        or GoldCompat.strictBattleUiForGame(self.game) then
      local bag = bagStateForMenu(self.game)
      if bag then
        State.activeBagActionMenu = self
        return
      end
    end

    State.activeBagActionMenu = nil
    State.activeShopMenu = nil
    State.activeShopList = nil
    State.activeShopQuantity = nil
    return originalMenuDraw(self)
  end

  -- Native Pokédex DATA page stays authoritative for update/A/B behavior.
  -- We only mark instances and suppress their opaque vanilla presentation.
  local dexEntryOK,DexEntryMenu=pcall(require,"src.ui.DexEntryMenu")
  if dexEntryOK and DexEntryMenu and DexEntryMenu.new
      and not DexEntryMenu.__gen3uiWrapped then
    DexEntryMenu.__gen3uiWrapped=true

    local originalDexEntryNew=DexEntryMenu.new
    DexEntryMenu.new=function(game,speciesOrOpts,onDone)
      local entry=originalDexEntryNew(game,speciesOrOpts,onDone)
      if entry then
        entry.__gen3uiDexEntry=true
        entry.isOpaque=false
        DexUI.entry=entry
      end
      return entry
    end

    if DexEntryMenu.draw then
      local originalDexEntryDraw=DexEntryMenu.draw
      DexEntryMenu.draw=function(self)
        if featureEnabled("revampedPokedex")
            and not self.__gen3uiDexEntryRenderFailed then
          DexUI.entry=self
          return
        end
        return originalDexEntryDraw(self)
      end
    end
  end

  -- Mark Bag-created ListMenu instances so shops/dex/PC lists remain vanilla.
  local originalBagNew = BagMenu.new
  BagMenu.new = function(game, opts)
    local list = originalBagNew(game, opts)
    list.__gen3uiBag = true

    if GoldCompat.generation=="gen1" then
      list.isOpaque=false
      list.__gen3uiCategorizedBag=true
      list.__gen3uiBagPocketIndex=1
      list.__gen3uiBagViewIndex=1
      list.__gen3uiBagViewScroll=0

      -- Pocket switching is presentation-only. Native ListMenu never receives
      -- Left/Right while the categorized UI is active.
      list.pageJump=false

      -- We mirror ListMenu's public repeat defaults for the visual cursor.
      list.__gen3uiBagRepeatDelay=list.repeatDelay or 16
      list.__gen3uiBagRepeatRate=list.repeatRate or 4
      list.__gen3uiBagViewHoldDir=nil
      list.__gen3uiBagViewHoldFrames=0

      local nativeUpdate=list.update

      local function selectedViewId(self)
        local row=gen1BagViewSelected(self)
        return row and row.value or nil
      end

      local function syncNativeSelection(self)
        local id=selectedViewId(self)
        local nativeIndex=gen1BagNativeIndexForId(self,id)
        if nativeIndex then
          self.index=nativeIndex
          -- Native scroll is irrelevant visually, but keep it valid for
          -- item subflows/mod hooks that inspect the Bag ListMenu.
          local nativeRows=self.rows or 7
          if self.index-(self.scroll or 0)>nativeRows then
            self.scroll=self.index-nativeRows
          elseif self.index-(self.scroll or 0)<1 then
            self.scroll=self.index-1
          end
        end
        return id,nativeIndex
      end

      local function moveView(self,dir)
        local moved=gen1BagMoveView(self,dir=="up" and -1 or 1)
        if moved then
          pcall(function()
            require("src.core.Sound").play(self.game.data,"Press_AB")
          end)
        end
        return moved
      end

      list.update=function(self,dt)
        if not (featureEnabled("revampedOverworldMenus")
            or GoldCompat.strictBattleUiForGame(self.game)) then
          return nativeUpdate(self,dt)
        end

        local input=self.game and self.game.input
        local preserve=selectedViewId(self)
        gen1BagRefresh(self,preserve)

        if not input then return end

        -- ---------------------------------------------------------------
        -- Horizontal pocket navigation.
        -- ---------------------------------------------------------------
        local leftEdge=input:wasPressed("left")
        local rightEdge=input:wasPressed("right")
        local leftDown=input:isDown("left")
        local rightDown=input:isDown("right")

        if not leftDown and not rightDown then
          self.__gen3uiBagPocketHeld=nil
        end

        local pocketDir=nil
        if leftEdge or (leftDown and self.__gen3uiBagPocketHeld~="left") then
          pocketDir="left"
        elseif rightEdge or (rightDown and self.__gen3uiBagPocketHeld~="right") then
          pocketDir="right"
        end

        if pocketDir then
          self.__gen3uiBagPocketHeld=pocketDir
          if pocketDir=="left" then
            self.__gen3uiBagPocketIndex=
              ((self.__gen3uiBagPocketIndex-2)%#GEN1_BAG_POCKETS)+1
          else
            self.__gen3uiBagPocketIndex=
              (self.__gen3uiBagPocketIndex%#GEN1_BAG_POCKETS)+1
          end

          self.__gen3uiBagViewIndex=1
          self.__gen3uiBagViewScroll=0
          self.__gen3uiBagViewHoldDir=nil
          self.__gen3uiBagViewHoldFrames=0
          self.swapIndex=nil
          gen1BagRefresh(self,nil)

          pcall(function()
            require("src.core.Sound").play(self.game.data,"Press_AB")
          end)
          return
        end

        -- ---------------------------------------------------------------
        -- Vertical navigation: one authoritative visual cursor.
        -- This mirrors ListMenu's edge/repeat behavior but never mutates the
        -- native flat inventory index until an actual item action is invoked.
        -- ---------------------------------------------------------------
        local moved=false
        if input:wasPressed("up") then
          moved=moveView(self,"up")
          self.__gen3uiBagViewHoldDir="up"
          self.__gen3uiBagViewHoldFrames=0
        elseif input:wasPressed("down") then
          moved=moveView(self,"down")
          self.__gen3uiBagViewHoldDir="down"
          self.__gen3uiBagViewHoldFrames=0
        elseif self.keyRepeat then
          -- Match native ListMenu exactly: held-direction repeat is opt-in.
          -- The normal Gen 1 Bag does NOT enable keyRepeat, so an ordinary
          -- press advances exactly one row and a held key does not race.
          local dir=self.__gen3uiBagViewHoldDir
          if dir and input:isDown(dir) then
            self.__gen3uiBagViewHoldFrames=
              (self.__gen3uiBagViewHoldFrames or 0)+1
            local delay=self.repeatDelay or 16
            local rate=self.repeatRate or 4
            local after=self.__gen3uiBagViewHoldFrames-delay
            if after>=0 and after%rate==0 then
              moved=moveView(self,dir)
            end
          else
            self.__gen3uiBagViewHoldDir=nil
            self.__gen3uiBagViewHoldFrames=0
          end
        else
          self.__gen3uiBagViewHoldDir=nil
          self.__gen3uiBagViewHoldFrames=0
        end
        if moved then return end

        -- ---------------------------------------------------------------
        -- Native actions. Translate the visual item to its flat native index
        -- immediately before delegating, so BagMenu's existing USE/TOSS/TM,
        -- quantity, target, consumption and mod hooks stay intact.
        -- ---------------------------------------------------------------
        if input:wasPressed("a") then
          local visualRow=gen1BagViewSelected(self)
          local selectedId=visualRow and visualRow.value or nil
          local selectedDef=selectedId and self.game and self.game.data
              and self.game.data.items and self.game.data.items[selectedId]

          -- TM/HMs must never pass through the generic field-item dispatcher.
          -- Run their actual boot -> target -> teach sequence directly.
          if selectedDef and selectedDef.machine then
            if not self.noSound and self.game and self.game.data then
              pcall(function()
                require("src.core.Sound").play(self.game.data,"Press_AB")
              end)
            end
            GoldCompat.gen1BagUseMachine(self,selectedId)
            return
          end

          -- Ordinary Items / Balls / Key Items use BagMenu's original
          -- onChoose callback, but with the EXACT categorized item ID.
          -- This avoids a second ListMenu input pass and eliminates any chance
          -- of the flat native cursor resolving a different item (for example
          -- a KEY ITEM dispatching an HM action).
          local _,nativeIndex=syncNativeSelection(self)
          if type(self.onChoose)=="function" and selectedId then
            if not self.noSound and self.game and self.game.data then
              pcall(function()
                require("src.core.Sound").play(self.game.data,"Press_AB")
              end)
            end
            local def=self.game.data.items and self.game.data.items[selectedId]
            self.onChoose({
              value=selectedId,
              label=(def and def.name) or selectedId,
              right="x"..tostring(
                (self.game.save.inventory and
                 self.game.save.inventory[selectedId]) or 1),
            },self)
            return
          end

          -- Compatibility fallback only if another mod removed onChoose.
          if nativeIndex then return nativeUpdate(self,dt) end
          return
        elseif input:wasPressed("select") then
          local selectedId=selectedViewId(self)
          syncNativeSelection(self)
          local result=nativeUpdate(self,dt)
          gen1BagRefresh(self,selectedId)
          return result
        elseif input:wasPressed("b") then
          -- B is entirely native: close the Bag and run its onCancel path.
          return nativeUpdate(self,dt)
        end

        -- No actionable input this frame. Do not run native navigation:
        -- keeping its flat cursor dormant prevents any competing movement.
      end

      gen1BagRefresh(list,nil)
    end
    return list
  end

  local originalListDraw = ListMenu.draw
  ListMenu.draw = function(self)
    if self.__gen3uiShopList then
      if self.__gen3uiMartRenderFailed then
        return originalListDraw(self)
      end
      if featureEnabled("revampedPokeMartUI") then
        State.activeShopList=self
        State.activeBagMenu=nil
        State.activePCList=nil
        return
      end
      State.activeShopList=nil
      return originalListDraw(self)
    end

    if self.__gen3uiPokedex then
      if not featureEnabled("revampedPokedex")
          or self.__gen3uiPokedexRenderFailed then
        DexUI.active=nil
        return originalListDraw(self)
      end
      DexUI.active=self
      State.activeBagMenu=nil
      State.activePCList=nil
      return
    end

    if self.__gen3uiPCList then
      if featureEnabled("revampedPokemonPC") then
        State.activePCList=self
        State.activeBagMenu=nil
        return
      end
      State.activePCList=nil
      return originalListDraw(self)
    end

    if self.__gen3uiElevator then
      if self.__gen3uiElevatorRenderFailed
          or not featureEnabled("revampedOverworldMenus") then
              return originalListDraw(self)
      end
      State.activeBagMenu=nil
      State.activePCList=nil
      return
    end

    local strictBattleBag=self.__gen3uiBag
      and GoldCompat.strictBattleUiForGame(self.game)
    if not featureEnabled("revampedOverworldMenus") and not strictBattleBag then
      State.activeBagMenu=nil
      return originalListDraw(self)
    end

    if self.__gen3uiBag then
      State.activeBagMenu=self
      State.activePCList=nil
      return
    end

    State.activeBagMenu=nil
    State.activePCList=nil
    return originalListDraw(self)
  end

  -- Native SummaryMenu owns STATS/MOVES input and page transitions.
  -- Suppress only its vanilla drawing and defer our presentation to render.hud.
  local SummaryMenu = require("src.ui.SummaryMenu")
  local originalSummaryDraw = SummaryMenu.draw
  local originalSummaryUpdate = SummaryMenu.update

  SummaryMenu.draw = function(self)
    if featureEnabled("revampedPokemonMenu")
        or GoldCompat.strictBattleUiForGame(self.game) then
      DexUI.summary=self
      return
    end
    if DexUI.summary==self then DexUI.summary=nil end
    return originalSummaryDraw(self)
  end

  SummaryMenu.update = function(self,dt)
    -- Native SummaryMenu owns A/B page transitions and closing. Add only the
    -- Gen 3-style party browsing behavior: while this summary is showing a
    -- member of the live party, Up/Down swaps the viewed Pokémon in-place.
    if (featureEnabled("revampedPokemonMenu")
          or GoldCompat.strictBattleUiForGame(self.game))
        and self.game and self.mon and self.game.input then
      if self.__gen3uiMoveManager then
        GoldCompat.updateMoveManager(self,self.game.input)
        return
      end
      -- Confirmed against the real src/ui/SummaryMenu.lua: :update(dt) only
      -- ever checks "a"/"b" (page 1->2, then close from page 2), so SELECT
      -- is completely free on EITHER page here, just like Gen 2's SummaryMenu
      -- accepts it from any page (it temporarily forces GREEN_PAGE itself
      -- before opening). Not requiring page==2 matters: a Summary always
      -- opens on page 1, so gating this to page 2 only meant SELECT visibly
      -- did nothing until the player had first flipped to MOVES -- easy to
      -- read as "the feature doesn't exist" rather than "wrong page."
      if self.game.input:wasPressed("select") then
        if GoldCompat.openMoveManager(self) then return end
      end
      local party=self.game.save and self.game.save.party
      if type(party)=="table" and #party>1 then
        local current=nil
        for i,m in ipairs(party) do
          if m==self.mon then
            current=i
            break
          end
        end

        if current then
          local delta=0
          if self.game.input:wasPressed("up") then
            delta=-1
          elseif self.game.input:wasPressed("down") then
            delta=1
          end

          if delta~=0 then
            local nextIndex=((current-1+delta)%#party)+1
            local nextMon=party[nextIndex]
            if nextMon then
              self.mon=nextMon

              -- Our renderer resolves the active sprite dynamically, so no
              -- SummaryMenu sprite cache rebuild is needed. Match the native
              -- summary-opening feel by playing the newly selected cry.
              pcall(function()
                require("src.core.Sound").playCry(self.game.data,nextMon.species)
              end)
              return
            end
          end
        end
      end
    end

    return originalSummaryUpdate(self,dt)
  end

  -- Real src/ui/PartyMenu.lua hardcodes `PartyMenu.isOpaque = true` at the
  -- module level (confirmed by reading it), so the state stack never even
  -- tries to render the overworld underneath -- this mod's own drawPartyFinal
  -- already deliberately paints no full-canvas backplate of its own ("keep
  -- the menu transparent so overlays such as the DV reader show through"),
  -- but that only matters once the engine is willing to draw what's behind
  -- this state at all. Previously only individual TM/HM- and item-picker
  -- instances got `party.isOpaque=false` (below), so the plain party screen
  -- opened from START stayed a fully solid backplate. Same class-level fix
  -- already proven safe here for TrainerCard/ManagerState: vanilla mode is
  -- unaffected because native PartyMenu.draw still paints its own full
  -- opaque background when the feature is off, so setting this at the class
  -- level (not per-instance, not gated on the live option) costs nothing.
  PartyMenu.isOpaque = false

  -- TM/HM target picking should remain on the Party screen through the
  -- teach/replace-move flow, matching the original games. PartyMenu already
  -- supports this behavior through keepOpen; opt TM/HM pickers into it.
  local originalPartyNew = PartyMenu.new
  PartyMenu.new = function(game, opts)
    opts = opts or {}
    if opts.tmhm then
      opts.keepOpen = true
    end

    local party = originalPartyNew(game, opts)

    if opts.tmhm then
      party.__gen3uiKeepTMBackground = true
      party.__gen3uiCustomPartyOwned = true
      party.isOpaque = false
      State.activeTMParty = party
      State.activeItemTargetParty = party
      State.activeBagActionMenu = nil
      State.activeBagMenu = nil
    elseif opts.pickOnly and not opts.battle then
      party.__gen3uiItemTarget = true
      party.__gen3uiCustomPartyOwned = true
      party.isOpaque = false

      local bag=bagStateForMenu(game)
      local row=bag and bag.items and bag.items[bag.index or 1]
      party.__gen3uiTargetItem=row and row.value or nil

      State.activeItemTargetParty = party
      State.activeParty = party
      State.activeBagActionMenu = nil
      State.activeBagMenu = nil
    end

    return party
  end

  -- Track MoveLearnMenu from creation so native prompt pages can retain the
  -- revamped Party screen underneath before actual move selection begins.
  local originalMoveLearnNew = MoveLearnMenu.new
  MoveLearnMenu.new = function(game, mon, newMoveId, onDone)
    -- Preserve the engine constructor EXACTLY. Dropping newMoveId/onDone corrupts
    -- the state and crashes once actual move replacement begins.
    local menu = originalMoveLearnNew(game, mon, newMoveId, onDone)
    if State.activeTMParty and menu and menu.mon and canIntegrateMoveLearn(game, menu) then
      State.activeTMPromptFlow = menu
    end
    return menu
  end

  -- TM move replacement uses the engine's native MoveLearnMenu INPUT/LOGIC,
  -- but during a kept-open TM Party flow its standalone draw is suppressed.
  -- The active selection is rendered inside the Party detail panel instead.
  local originalMoveLearnDraw = MoveLearnMenu.draw
  MoveLearnMenu.draw = function(self)
    if canIntegrateMoveLearn(self.game, self) then
      State.activeTMPromptFlow = self
      if self.selecting then
        State.activeMoveLearn = self
        return
      end
    end

    -- Level-up move learning inside battle reuses the custom Pokémon-menu
    -- presentation. Native MoveLearnMenu still owns every input/callback.
    local battle=battleStateInStack(self.game)
    if battleUiPresentationEnabled()
        and (featureEnabled("revampedPokemonMenu")
          or GoldCompat.strictBattleUiForGame(self.game))
        and battle
        and self.selecting then
      State.activeBattleMoveLearn=self
      State.activeBattleMoveParty=makeBattleMovePartyState(self.game,self)
      State.activeBattle=battle
      return
    end

    if State.activeMoveLearn == self then State.activeMoveLearn = nil end
    if State.activeBattleMoveLearn == self then
      State.activeBattleMoveLearn=nil
      State.activeBattleMoveParty=nil
    end
    return originalMoveLearnDraw(self)
  end

  -- Pokémon selection: full visual replacement, existing input/state unchanged.
  -- Uses Gen1Recomp's own icon renderer so sprite/mon mods remain compatible.
  local originalPartyDraw = PartyMenu.draw
  PartyMenu.draw = function(self)
    if not (featureEnabled("revampedPokemonMenu")
        or GoldCompat.strictBattleUiForGame(self.game)) then
      State.activeParty = nil
      State.activeTMParty = nil
      State.activeMoveLearn = nil
      State.activeTMPromptFlow = nil
      return originalPartyDraw(self)
    end
    State.activeParty = self
    if self.__gen3uiItemTarget or self.__gen3uiKeepTMBackground then
      State.activeItemTargetParty = self
    end
  end
  local StatBox=BattleState.StatBox
  if StatBox and StatBox.draw and not StatBox.__gen3uiWrapped then
    StatBox.__gen3uiWrapped=true
    local originalStatDraw=StatBox.draw
    StatBox.draw=function(self)
      local battle=battleStateInStack(self.game)
      if not (battleUiPresentationEnabled() and battle and self.mon) then
        return originalStatDraw(self)
      end

      State.activeBattle=battle

      -- StatBox is a pushed 160x144 battle state. Draw here at its guaranteed
      -- native callback, but use Gen1Recomp's own pixel Font so the renderer's
      -- final upscale remains crisp instead of magnifying a smooth font.
      local g=love.graphics
      local s=self.mon.stats or {}
      local def=battle.data and battle.data.pokemon
          and battle.data.pokemon[self.mon.species]
      local name=self.mon.nickname or (def and def.name) or "POKéMON"

      local wide=false
      if battle.wideLayout then
        local ok,value=pcall(battle.wideLayout,battle)
        wide=ok and value or false
      end

      -- Anchor to the right side of either classic or wide battle canvas.
      local canvasW=wide and 304 or 160
      local w,h=84,56
      local x=canvasW-w-14
      local y=144-h-14

      g.push("all")

      -- Opaque charcoal outer plate.
      g.setColor(0.10,0.10,0.09,1)
      g.rectangle("fill",x,y,w,h)

      -- Cream paper.
      g.setColor(0.98,0.965,0.90,1)
      g.rectangle("fill",x+2,y+2,w-4,h-4)

      -- Gold inner border.
      g.setColor(0.66,0.50,0.20,1)
      g.rectangle("line",x+3,y+3,w-6,h-6)

      -- Native pixel typography. Font.draw uses the exact Gen1Recomp glyph
      -- renderer and therefore survives integer/fractional battle scaling cleanly.
      g.setColor(0.08,0.08,0.07,1)

      -- Pokémon name gets the full card width. Never hard-truncate it.
      -- Scale only this header if a long name exceeds the available width.
      local title=tostring(name or "POKéMON")
      local titleMaxW=w-12
      local titleScale=math.min(1,titleMaxW/math.max(1,#title*8))

      if titleScale<0.999 then
        g.push()
        g.translate(x+6,y+6)
        g.scale(titleScale,titleScale)
        EngineFont.draw(title,0,0)
        g.pop()
      else
        EngineFont.draw(title,x+6,y+6)
      end

      -- Level gets its own compact badge sitting above the card.
      local levelTag="Lv."..tostring(self.mon.level or "?")
      local levelW=#levelTag*8 + 10
      local levelX=x+w-levelW
      local levelY=y-11

      g.setColor(0.10,0.10,0.09,1)
      g.rectangle("fill",levelX,levelY,levelW,12)
      g.setColor(0.98,0.965,0.90,1)
      g.rectangle("fill",levelX+2,levelY+2,levelW-4,8)
      g.setColor(0.66,0.50,0.20,1)
      g.rectangle("line",levelX+2,levelY+2,levelW-4,8)
      g.setColor(0.08,0.08,0.07,1)
      EngineFont.draw(levelTag,levelX+5,levelY+2)

      g.setColor(0.66,0.50,0.20,1)
      g.rectangle("fill",x+5,y+18,w-10,1)
      g.setColor(0.08,0.08,0.07,1)

      local rows={
        {"ATK",s.attack or 0},
        {"DEF",s.defense or 0},
        {"SPD",s.speed or 0},
        {"SPC",s.special or 0},
      }

      for i,row in ipairs(rows) do
        local yy=y+22+(i-1)*8

        if i%2==1 then
          g.setColor(0.90,0.88,0.80,1)
          g.rectangle("fill",x+4,yy-1,w-8,8)
        end

        g.setColor(0.08,0.08,0.07,1)
        EngineFont.draw(row[1],x+7,yy)
        local value=("%3d"):format(row[2])
        EngineFont.draw(value,x+w-7-(#value*8),yy)
      end

      -- Native-style continue hint; input remains StatBox:update unchanged.

      g.setColor(1,1,1,1)
      g.pop()
    end
  end

  if mod and mod.log then
    pcall(function()
      mod.log:info("Gen 3 Inspired UI Overhaul: overworld START/Bag/Party UI alpha active")
    end)
  end
end


-- -------------------------------------------------------------------------
-- Final-pass FRLG overworld menus
-- -------------------------------------------------------------------------

local function uiTopState(game, state)
  if not (game and game.stack and game.stack.states and state) then return false end
  local top = (game.stack.top and game.stack:top()) or game.stack.states[#game.stack.states]
  return top == state
end


local function finalCanvas()
  local sw, sh = love.graphics.getDimensions()
  local boxScale=GoldCompat.userBoxScale()
  local cached=GoldCompat.finalCanvasCache
  if cached and cached.sw==sw and cached.sh==sh and cached.boxScale==boxScale then
    return cached.ox,cached.oy,cached.scale
  end

  local raw = math.min(sw / 160, sh / 144)
  local scale = math.floor(raw)
  if scale < 1 then scale = raw end

  -- UI BOX SIZE is intentionally allowed to exceed the full 160x144
  -- fit-scale slightly. Most hanging panels have generous logical margins,
  -- so this makes LARGE / X-LARGE visibly meaningful without changing their
  -- internal layout. COMPACT still shrinks normally.
  if boxScale>1 then
    scale=math.min(scale*boxScale,raw*1.14)
  else
    scale=scale*boxScale
  end

  local ox = math.floor((sw - 160*scale) * 0.5 + 0.5)
  local oy = math.floor((sh - 144*scale) * 0.5 + 0.5)
  GoldCompat.finalCanvasCache={
    sw=sw,sh=sh,boxScale=boxScale,ox=ox,oy=oy,scale=scale,
  }
  return ox, oy, scale
end

-- Full-screen interfaces must honor the real display bounds at every UI box
-- size. Hanging/overworld panels continue to use finalCanvas(), which retains
-- its intentional slight Large/X-Large overscan.
local function safeFullCanvas(marginPx)
  local sw,sh=love.graphics.getDimensions()
  local margin=marginPx or 4
  local boxScale=GoldCompat.userBoxScale()
  local cached=GoldCompat.safeFullCanvasCache
  if cached and cached.sw==sw and cached.sh==sh and cached.margin==margin
      and cached.boxScale==boxScale then
    return cached.ox,cached.oy,cached.scale
  end

  local raw=math.min((sw-margin*2)/160,(sh-margin*2)/144)
  local base=math.floor(math.min(sw/160,sh/144))
  if base<1 then base=math.min(sw/160,sh/144) end
  local requested=base*boxScale
  local scale=math.min(requested,raw)
  if scale<=0 then scale=raw end
  local ox=math.floor((sw-160*scale)*0.5+0.5)
  local oy=math.floor((sh-144*scale)*0.5+0.5)
  GoldCompat.safeFullCanvasCache={
    sw=sw,sh=sh,margin=margin,boxScale=boxScale,ox=ox,oy=oy,scale=scale,
  }
  return ox,oy,scale
end

local function finalText(text, lx, ly, logicalSize, color, ox, oy, sc, align, logicalWidth)
  local sx = math.floor(ox + lx*sc + 0.5)
  local sy = math.floor(oy + ly*sc + 0.5)
  local pxSize = math.max(4, math.floor(logicalSize*sc + 0.5))
  local pxWidth = logicalWidth and math.floor(logicalWidth*sc + 0.5) or nil

  love.graphics.push("all")
  love.graphics.origin()
  printText(text, sx, sy, pxSize, color, align, pxWidth)
  if pxSize >= 10 and GoldCompat.userTextWeight()>=0.40 then
    printText(text, sx+1, sy, pxSize, color, align, pxWidth)
  end
  love.graphics.pop()
end

local function finalTextWidth(text, logicalSize, sc)
  local pxSize = math.max(4, math.floor(logicalSize*sc + 0.5))
  return font(pxSize*UI_TEXT_SCALE*GoldCompat.userTextScale()):getWidth(tostring(text or "")) / math.max(sc,0.001)
end


local function drawShopPanel(x,y,w,h,selected)
  local g=love.graphics
  g.setColor(0.14,0.14,0.13,1)
  roundedRect("fill",x,y,w,h,3)
  g.setColor(selected and {0.975,0.955,0.88,1}
                      or {0.99,0.985,0.955,1})
  roundedRect("fill",x+2,y+2,w-4,h-4,2)
  if selected then
    g.setColor(0.72,0.58,0.28,1)
    roundedRect("line",x+3,y+3,w-6,h-6,2)
  end
end

local function shopMoney(game)
  return tonumber(game and game.save and game.save.money) or 0
end

function GoldCompat.drawShopFrame(game,title)
  local ox,oy,sc=finalCanvas()
  local g=love.graphics
  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  g.setColor(0.94,0.93,0.87,1)
  g.rectangle("fill",0,0,160,144)

  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,4,152,16)
  g.setColor(0.99,0.985,0.955,1)
  g.rectangle("fill",5,5,150,14)
  g.pop()

  finalText(title or "POKé MART",10,7,5.0,{0.06,0.06,0.06,1},ox,oy,sc)

  local money=("¥%d"):format(shopMoney(game))
  local mw=finalTextWidth(money,4.4,sc)
  finalText(money,150-mw,8,4.4,{0.12,0.12,0.11,1},ox,oy,sc)

  return ox,oy,sc
end

local function drawShopMainFinal(game,state)
  -- Matches Gen 2's own GoldCompat.drawGoldMart "top" phase layout exactly
  -- (same frame, same panel position/size, same footer box) so BUY/SELL/EXIT
  -- reads as one consistent Mart presentation across both generations.
  local ox,oy,sc=GoldCompat.drawShopFrame(game,"POKé MART")
  local g=love.graphics
  local items=state.items or {}
  local count=#items
  if count<1 then return end

  local x,y,w,h=94,25,58,49
  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)
  drawShopPanel(x,y,w,h,false)
  for i=1,count do
    local yy=y+8+(i-1)*13
    if i==(state.index or 1) then
      g.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",x+5,yy-1,w-10,10,1.5)
    end
  end
  g.pop()

  for i,item in ipairs(items) do
    local yy=y+9+(i-1)*13
    local selected=i==(state.index or 1)
    local label=tostring(item.label or "")
    if label:upper()=="QUIT" then label="EXIT" end
    finalText(label,x+12,yy,4.0,
      selected and {1,1,1,1} or {0.06,0.06,0.06,1},
      ox,oy,sc)
  end

  -- ShopMenu.lua's own drawClerk() used to print `menu.footer` (the clerk's
  -- greeting/receipt line -- it's plain text baked onto the Mart's own
  -- canvas each frame, never a real pushed TextBox, so this mod's existing
  -- dialogue theme never had a chance to catch it) directly in vanilla
  -- style. Now that drawClerk is suppressed (see the ShopMenu.new wrap in
  -- installPCIntegration), draw that same text ourselves, styled like the
  -- footer box every other Mart screen in this renderer already uses.
  local footer=tostring(state.footer or "")
  if footer~="" then
    local pages=TextBox.paginate(footer)
    local flat={}
    for _,page in ipairs(pages or {}) do
      for _,line in ipairs(page) do flat[#flat+1]=line end
    end
    local bx,by,bw,bh=4,109,152,31
    g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
    g.setColor(0.08,0.08,0.08,1)
    g.rectangle("fill",bx,by,bw,bh)
    g.setColor(0.99,0.985,0.95,1)
    g.rectangle("fill",bx+2,by+2,bw-4,bh-4)
    g.pop()
    local firstLine=math.max(1,#flat-1)
    for i=firstLine,#flat do
      finalText(flat[i],bx+7,by+7+(i-firstLine)*9,3.7,
        {0.06,0.06,0.06,1},ox,oy,sc)
    end
  end
end

function GoldCompat.shopFirstVisible(state)
  local rows=5
  local n=#(state.items or {})
  local selected=math.max(1,math.min(state.index or 1,math.max(1,n)))
  local first=math.max(1,selected-rows+1)
  if n>rows then first=math.min(first,n-rows+1) end
  return first,selected,rows
end

-- Gen 1 Mart SELL categorized body -- pocket tabs (ITEMS/BALLS/KEY/TM-HM)
-- plus a windowed row list sourced from state.__gen3uiShopSellViewRows
-- (maintained every frame by the ListMenu.new SELL input wrap in
-- installPCIntegration). Confined to the same 6,25,148,78 panel BUY still
-- uses so both Mart screens read as one consistent frame; only the body
-- below the panel's top edge differs (a short tab strip instead of the
-- flat list starting immediately under the border).
local function drawShopSellPocketBody(game,state,ox,oy,sc)
  local g=love.graphics
  local x,y,w,h=6,25,148,78

  g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
  drawShopPanel(x,y,w,h,false)

  local pocketIndex=state.__gen3uiShopSellPocketIndex or 1
  local pocket=GEN1_BAG_POCKETS[pocketIndex] or GEN1_BAG_POCKETS[1]
  local tabs={"ITEMS","BALLS","KEY","TM/HM"}
  local ids={"ITEM","BALL","KEY_ITEM","TM_HM"}
  local tabW=(w-8)/4

  for i in ipairs(tabs) do
    local tx=x+4+(i-1)*tabW
    local selected=pocket.id==ids[i]
    g.setColor(selected and 0.11 or 0.86,
               selected and 0.28 or 0.84,
               selected and 0.38 or 0.77,1)
    roundedRect("fill",tx,y+3,tabW-1,10,1.5)
  end
  g.setColor(0.20,0.19,0.16,1)
  g.rectangle("fill",x+3,y+15,w-6,1)

  local rows=state.__gen3uiShopSellViewRows or {}
  local total=#rows+1 -- +1: CANCEL is always the trailing selectable slot
  local index=state.__gen3uiShopSellViewIndex or 1
  local visible=GoldCompat.shopSellVisibleRows()
  local rowH=GoldCompat.bagPackRowHeight()
  local listTop=y+18
  local first=(state.__gen3uiShopSellViewScroll or 0)+1

  for row=1,visible do
    local idx=first+row-1
    if idx<=total and idx==index then
      local yy=listTop+(row-1)*rowH
      g.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",x+5,yy-1,w-10,rowH-1,2)
      g.setColor(0.70,0.56,0.28,1)
      roundedRect("line",x+6,yy,w-12,rowH-3,2)
    end
  end
  g.pop()

  for i,label in ipairs(tabs) do
    local tx=x+4+(i-1)*tabW
    GoldCompat.panelText(label,tx,y+5,3.0,
      pocket.id==ids[i] and {0.98,0.97,0.92,1} or {0.22,0.22,0.20,1},
      "center",tabW-1)
  end

  for row=1,visible do
    local idx=first+row-1
    if idx>total then break end
    local yy=listTop+(row-1)*rowH
    local selected=idx==index
    if idx<=#rows then
      local item=rows[idx]
      finalText(tostring(item.label or ""),x+12,yy+1,3.9,
        selected and {0.98,0.97,0.92,1} or {0.07,0.07,0.07,1},
        ox,oy,sc,"left",w-38)
      if item.count then
        local right="x"..tostring(item.count)
        local rw=finalTextWidth(right,3.9,sc)
        finalText(right,x+w-9-rw,yy+1,3.9,
          selected and {0.98,0.97,0.92,1} or {0.12,0.12,0.11,1},
          ox,oy,sc)
      end
    else
      finalText(Strings("CANCEL"),x+12,yy+1,3.9,
        selected and {0.98,0.97,0.92,1} or {0.07,0.07,0.07,1},
        ox,oy,sc,"left",w-38)
    end
  end

  if first>1 then
    finalText("^",x+w-9,y+16,2.8,{0.30,0.30,0.27,1},ox,oy,sc)
  end
  if first+visible-1<total then
    finalText("v",x+w-9,y+h-8,2.8,{0.30,0.30,0.27,1},ox,oy,sc)
  end
end

local function drawShopListFinal(game,state)
  -- Gen 1's real buy()/sell() (src/ui/ShopMenu.lua) always push this list
  -- with title=nil (see the ListMenu.new wrap in installPCIntegration for
  -- why), so state.title is never actually "SELL" here -- read the flag that
  -- wrap already worked out structurally instead.
  local ox,oy,sc=GoldCompat.drawShopFrame(game,
    state.__gen3uiShopSell and "POKé MART — SELL" or "POKé MART — BUY")
  local g=love.graphics

  -- The categorized pocket UI only ever applies to Gen 1's SELL screen --
  -- confirmed by the user that the categorization system is already built
  -- and working (the Bag), and only the Mart's item menu lacked it. BUY
  -- keeps the flat list unconditionally (never asked for, and Gen 1 BUY
  -- stock isn't drawn from the player's own categorized inventory anyway).
  if GoldCompat.generation=="gen1" and state.__gen3uiShopSell
      and state.__gen3uiShopSellViewRows then
    drawShopSellPocketBody(game,state,ox,oy,sc)
  else
    g.push("all")
    g.translate(ox,oy)
    g.scale(sc,sc)
    drawShopPanel(6,25,148,78,false)
    g.pop()

    local first,selected,rows=GoldCompat.shopFirstVisible(state)
    for row=1,rows do
      local idx=first+row-1
      local item=state.items and state.items[idx]
      if item then
        local y=31+(row-1)*14
        if idx==selected then
          g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
          g.setColor(0.10,0.10,0.10,1)
          roundedRect("fill",11,y-2,138,12,2)
          g.setColor(0.70,0.56,0.28,1)
          roundedRect("line",12,y-1,136,10,2)
          g.pop()
        end
        finalText(tostring(item.label or ""),18,y,3.9,
          idx==selected and {0.98,0.97,0.92,1} or {0.07,0.07,0.07,1},
          ox,oy,sc,"left",85)
        -- Gen 1's real item shape carries the badge as `.price` (a
        -- ¥-string, buy()) or `.count` (a bare number, sell()) rather than
        -- a pre-formatted `.right` -- fall back to those when unset.
        local right=item.right
        if not right and item.price then right=tostring(item.price) end
        if not right and item.count then right="x"..tostring(item.count) end
        if right then
          local rw=finalTextWidth(tostring(right),3.9,sc)
          finalText(tostring(right),145-rw,y,3.9,
            idx==selected and {0.98,0.97,0.92,1} or {0.12,0.12,0.11,1},
            ox,oy,sc)
        end
      end
    end
  end

  g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,108,152,32)
  g.setColor(0.99,0.985,0.95,1)
  g.rectangle("fill",6,110,148,28)
  g.pop()

  local footer=tostring(state.footer or "Take your time.")
  local pages=TextBox.paginate(footer)
  local flat={}
  for _,page in ipairs(pages or {}) do
    for _,line in ipairs(page) do flat[#flat+1]=line end
  end
  local firstLine=math.max(1,#flat-1)
  for i=firstLine,#flat do
    finalText(flat[i],11,116+(i-firstLine)*9,3.7,{0.06,0.06,0.06,1},ox,oy,sc)
  end
end

-- Elevator floor picker (Celadon Mart/Silph Co/Rocket Hideout -- all three
-- share this one real builder, data/scripts/story3.lua's `elevator()`).
-- Native floats this bordered list directly over the still-visible map/3D
-- scene rather than replacing the screen the way the Mart does, so this
-- deliberately reuses the floating-panel language already proven for the
-- Party field-move submenu (GoldCompat.frlgMenuPanel/frlgSelection) instead
-- of GoldCompat.drawShopFrame's full-canvas fill. The separate "Which floor
-- do you want?" TextBox that always sits underneath this list on the real
-- stack already gets this mod's ordinary, unconditional dialogue theming
-- (same reasoning as the Gen 1 SAVE panel's confirm box), so this renderer
-- only needs to cover the floor list itself.
local function drawElevatorFloorsFinal(game,state)
  local ox,oy,sc=finalCanvas()
  local g=love.graphics
  local items=state.items or {}
  local first,selected,rows=GoldCompat.shopFirstVisible(state)
  rows=math.min(rows,#items)
  if rows<1 then return end

  local w=68
  -- Row label draws at 4.2 below (finalText(...,4.2,...)) -- match that
  -- real size so this list's row height/highlight scale with TEXT SIZE the
  -- same way the Bag/Pack list already does (General Sweep, v2.1.28).
  local rowH=GoldCompat.dynamicRowHeight(4.2,11,3)
  local h=8+rows*rowH
  local x=160-w-8
  local y=math.max(6,math.min(120-h,72-math.floor(h/2)))

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)
  GoldCompat.frlgMenuPanel(x,y,w,h)
  for row=1,rows do
    if (first+row-1)==selected then
      GoldCompat.frlgSelection(x+3,y+4+(row-1)*rowH,w-6,rowH-2)
    end
  end
  g.pop()

  for row=1,rows do
    local idx=first+row-1
    local item=items[idx]
    if item then
      local yy=y+7+(row-1)*rowH
      finalText(tostring(item.label or ""),x+8,yy,4.2,
        idx==selected and {1,1,1,1} or {0.08,0.08,0.08,1},
        ox,oy,sc,"left",w-16)
    end
  end

  if first>1 then
    finalText("^",x+w-13,y+2,3.4,{0.32,0.32,0.30,1},ox,oy,sc)
  end
  if first+rows-1<#items then
    finalText("v",x+w-13,y+h-10,3.4,{0.32,0.32,0.30,1},ox,oy,sc)
  end
end

function GoldCompat.drawShopQuantityFinal(game,shop,qty)
  -- drawShopListFinal already renders both BUY and SELL rows correctly
  -- (see its own __gen3uiShopSell-driven header/badge logic above); the
  -- drawShopSellBagFinal branch this used to call was unreachable dead code
  -- -- it referenced a local defined later in the file, so it always threw
  -- and fell back to native rendering whenever a SELL quantity prompt
  -- opened, on top of drawBagFinal's own "legacy fallback" (an empty box
  -- with no items) for any list that isn't the real Bag menu, which this
  -- never was to begin with.
  drawShopListFinal(game,shop)
  local ox,oy,sc=finalCanvas()
  local g=love.graphics
  g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
  drawShopPanel(83,73,68,28,true)
  g.pop()

  finalText("HOW MANY?",90,78,3.2,{0.28,0.27,0.23,1},ox,oy,sc)
  finalText(("×%02d"):format(qty.qty or 1),91,87,5.0,{0.06,0.06,0.06,1},ox,oy,sc)
  if qty.unitPrice then
    local total=(qty.qty or 1)*qty.unitPrice
    local amount=("¥%d"):format(total)
    local aw=finalTextWidth(amount,4.6,sc)
    finalText(amount,144-aw,87,4.6,{0.06,0.06,0.06,1},ox,oy,sc)
  end
end

function GoldCompat.drawStartFinal(game, state)
  local g = love.graphics
  local ox,oy,sc = finalCanvas()

  if state.__gen3uiUISettings then
    local visible=math.min(state.maxVisible or #state.items,#state.items)
    -- Row label draws at 3.2 below -- dynamic to match TEXT SIZE (General
    -- Sweep, v2.1.28), same as every other restyled selection list.
    local rowH=GoldCompat.dynamicRowHeight(3.2,9,3)
    local w=104
    local h=visible*rowH+20
    local x=52
    local y=math.max(4,math.floor((144-h)/2))

    g.push("all")
    g.translate(ox,oy)
    g.scale(sc,sc)

    -- Same floating panel language as START, simply widened for label/value
    -- pairs. The overworld remains fully visible behind it.
    g.setColor(0.05,0.05,0.05,0.35)
    g.rectangle("fill",x+2,y+2,w,h)
    g.setColor(0.08,0.08,0.07,1)
    g.rectangle("fill",x,y,w,h)
    g.setColor(0.99,0.985,0.95,1)
    g.rectangle("fill",x+2,y+2,w-4,h-4)
    drawUnifiedBorder(x,y,w,h,0)

    g.setColor(0.10,0.10,0.09,1)
    g.rectangle("fill",x+4,y+4,w-8,12)

    for row=1,visible do
      local item=state.items[state.scroll+row]
      if not item then break end
      local yy=y+18+(row-1)*rowH
      if (state.scroll+row)==state.index then
        g.setColor(0.10,0.10,0.09,1)
        roundedRect("fill",x+4,yy-1,w-8,rowH-1,2)
      end
    end
    g.pop()

    finalText("UI OPTIONS",x+9,y+6,4.7,{1,1,1,1},ox,oy,sc)

    for row=1,visible do
      local item=state.items[state.scroll+row]
      if not item then break end
      local yy=y+18+(row-1)*rowH
      local selected=(state.scroll+row)==state.index
      local cfg=item.__gen3uiUIRow
      local value=cfg and DexUI.optionDisplay(cfg) or ""
      finalText(item.label,x+8,yy+1,3.2,
        selected and {1,1,1,1} or {0.06,0.06,0.06,1},
        ox,oy,sc,"left",67)
      finalText(value,x+76,yy+1,3.1,
        selected and {1,1,1,1} or {0.24,0.24,0.22,1},
        ox,oy,sc,"right",20)
    end

    finalText("A: CHANGE   B: BACK",x+8,y+h-6,2.55,
      {0.30,0.30,0.28,1},ox,oy,sc)
    return
  end

  local visible = (state.maxVisible and math.min(state.maxVisible, #state.items)) or #state.items

  -- Row label draws at 5 below -- dynamic to match TEXT SIZE (General
  -- Sweep, v2.1.28).
  local rowH = GoldCompat.dynamicRowHeight(5,10,3)
  local w = 60
  local h = visible*rowH + 8
  local x = 96
  local y = math.max(3, math.floor((144-h)/2))

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  g.setColor(0.05,0.05,0.05,0.35)
  g.rectangle("fill",x+2,y+2,w,h)

  g.setColor(0.08,0.08,0.07,1)
  g.rectangle("fill",x,y,w,h)
  g.setColor(0.99,0.985,0.95,1)
  g.rectangle("fill",x+2,y+2,w-4,h-4)

  drawUnifiedBorder(x,y,w,h,0)

  for row=1,visible do
    local item = state.items[state.scroll + row]
    if not item then break end
    local ry = y + 4 + (row-1)*rowH
    if (state.scroll + row) == state.index then
      g.setColor(0.10,0.10,0.09,1)
      g.rectangle("fill",x+4,ry,w-8,rowH-1)
    end
  end
  g.pop()

  for row=1,visible do
    local item = state.items[state.scroll + row]
    if not item then break end
    local ry = y + 4 + (row-1)*rowH
    local selected = (state.scroll + row) == state.index
    finalText(item.label,x+9,ry+1,5,
      selected and {1,1,1,1} or {0.04,0.04,0.04,1},
      ox,oy,sc)
  end
end


function GoldCompat.drawBagActionFinal(game, state)
  local g = love.graphics
  local ox,oy,sc = finalCanvas()

  local items = state.items or {}
  local count = #items
  if count < 1 then return end

  -- Row label draws at 5 below -- dynamic to match TEXT SIZE (General
  -- Sweep, v2.1.28).
  local rowH = GoldCompat.dynamicRowHeight(5,10,3)
  local w = 48
  local h = count*rowH + 8
  local x = 107
  local y = math.max(5, 105 - h)

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  g.setColor(0.05,0.05,0.05,0.35)
  g.rectangle("fill",x+2,y+2,w,h)

  g.setColor(0.08,0.08,0.07,1)
  g.rectangle("fill",x,y,w,h)

  g.setColor(0.99,0.985,0.95,1)
  g.rectangle("fill",x+2,y+2,w-4,h-4)

  drawUnifiedBorder(x,y,w,h,0)

  for i=1,count do
    local ry = y + 4 + (i-1)*rowH
    if i == (state.index or 1) then
      g.setColor(0.10,0.10,0.09,1)
      g.rectangle("fill",x+4,ry,w-8,rowH-1)
    end
  end

  g.pop()

  for i=1,count do
    local item = items[i]
    local label = item and (item.label or item.text or tostring(item)) or ""
    local ry = y + 4 + (i-1)*rowH
    local selected = i == (state.index or 1)

    finalText(label,x+9,ry+1,5,
      selected and {1,1,1,1} or {0.04,0.04,0.04,1},
      ox,oy,sc)
  end
end

local function drawBagFinal(game, state)
  if GoldCompat.generation=="gen1"
      and state and state.__gen3uiCategorizedBag
      and GoldCompat.drawGoldPack then
    return GoldCompat.drawGoldPack(gen1BagGoldAdapter(state),
      love.graphics.getWidth(),love.graphics.getHeight(),false)
  end

  -- Legacy fallback for non-Gen1 callers.
  local g = love.graphics
  local ox,oy,sc = finalCanvas()
  local x,y,w,h = 5,5,150,134

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)
  g.setColor(0.08,0.08,0.07,1)
  g.rectangle("fill",x,y,w,h)
  g.setColor(0.99,0.985,0.95,1)
  g.rectangle("fill",x+2,y+2,w-4,h-4)
  drawUnifiedBorder(x,y,w,h,0)
  g.pop()

  finalText(Strings("BAG"),x+9,y+5,6,
    {0.04,0.04,0.04,1},ox,oy,sc)
end

-- (Removed: drawShopSellBagFinal, an unfinished SELL-via-Bag-layout renderer
-- that was never actually reachable -- it was defined below every call site
-- that referenced it, so each call always hit a nil global and threw, and
-- even fixed it would have fallen into drawBagFinal's "legacy fallback"
-- (an empty box, no items) for anything that isn't a real Bag menu, which a
-- Mart's ListMenu never is. drawShopListFinal renders BUY and SELL rows
-- correctly on its own -- see its __gen3uiShopSell branch above -- so every
-- former call site now just uses that instead.)


-- -------------------------------------------------------------------------
-- Final-pass FRLG Party screen
-- -------------------------------------------------------------------------

local function partyTopState(game, party)
  if not (game and game.stack and game.stack.states and party) then return false end
  local top = (game.stack.top and game.stack:top()) or game.stack.states[#game.stack.states]
  return top == party
end


local function partyInStack(game, party)
  if not (game and game.stack and game.stack.states and party) then return false end
  for _,state in ipairs(game.stack.states) do
    if state == party then return true end
  end
  return false
end

local STONE_ITEM_IDS={
  FIRE_STONE=true,
  WATER_STONE=true,
  THUNDER_STONE=true,
  LEAF_STONE=true,
  MOON_STONE=true,
}

local function itemTargetIsStone(state)
  return state and STONE_ITEM_IDS[state.__gen3uiTargetItem] == true
end

function GoldCompat.stoneAllowedForMon(game,state,mon)
  if not (game and state and mon and itemTargetIsStone(state)) then
    return false
  end

  local ok,target=pcall(Evolution.pendingFor,game,mon,{
    kind="item",
    item=state.__gen3uiTargetItem,
  })
  return ok and target ~= nil
end


local function partyShouldRenderBehindTM(game, party)
  if not party then return false end
  if not party.keepOpen then return false end
  if not (party.tmhm or party.__gen3uiKeepTMBackground) then return false end
  return partyInStack(game, party)
end


-- -------------------------------------------------------------------------
-- Selected Pokémon battle portrait
-- -------------------------------------------------------------------------
-- Sprite-source compatibility is isolated in the resolver scope above.
-- The UI owns only layout/drawing; the resolver reads the active sprite stack.

-- Draws a small on-screen badge naming the exact reason a Battle-Art-shaped
-- mod's interface art wasn't used for this portrait -- ONLY while such a mod
-- is actually loaded this session, so a user without one never sees it.
-- Added because asking a user to go find and read a mod log turned out not
-- to be a reliable way to surface a diagnostic; this renders directly in the
-- box that's wrong.
--
-- drawSelectedBattleSprite is called from several different transform
-- contexts: some callers stay inside the logical 160x144 g.scale(sc,sc)
-- transform, others already escape to real screen pixels via g.origin()
-- first and pass already-scaled coordinates. Rather than assume which one
-- is active, transformPoint() reads whatever transform IS active right now
-- and converts this box's corners to real screen pixels, so the badge lands
-- correctly either way.
local function drawBattleArtDebugBadge(code, x, y, w, h)
  local g = love.graphics
  if type(g.transformPoint) ~= "function" then return end
  local label = "BA:" .. tostring(code or "?")

  -- Anchor at the box's bottom-left corner, in real screen pixels, regardless
  -- of which transform is active at the call site.
  local ok, sx, sy = pcall(g.transformPoint, x, y + h)
  if not (ok and sx and sy) then return end

  g.push("all")
  g.origin()

  -- CRITICAL: explicitly clear any active shader. g.push("all") only saves
  -- it to restore later -- it stays BOUND for every draw call inside this
  -- push/pop block, including this badge's own. Several call sites of
  -- drawSelectedBattleSprite (GoldCompat.drawCleanResolvedPortrait, and any
  -- caller still holding that shader from an adjacent draw) run under
  -- GoldCompat.menuPortraitShader(), which makes any near-white pixel
  -- (r,g,b>0.985) fully transparent -- it exists to strip white mattes out
  -- of Battle Art images. A prior version of this badge drew pure white text
  -- without clearing that shader, so the shader quietly erased every glyph
  -- while leaving the (non-white, unaffected) red background rectangle
  -- fully visible -- exactly the "solid red box, no legible text" reported
  -- twice now. Belt-and-suspenders: text color below is also plain black,
  -- not white, so it survives even if some other white-stripping shader is
  -- ever bound here in the future.
  g.setShader()

  -- Fixed real-pixel font size, NOT derived from the (often tiny, e.g.
  -- 30x27-logical-pixel) portrait box -- an earlier version sized the font
  -- off a 5-logical-pixel-tall strip, which produced a font many times
  -- taller than that strip, so the glyphs rendered mostly outside the
  -- visible rectangle and looked like a blank colored bar with no text.
  local f = font and font(13) or g.newFont(13)
  local old = g.getFont()
  g.setFont(f)
  local tw, th = f:getWidth(label), f:getHeight()
  local pad = 2
  local bx, by = sx, sy - th - pad*2

  g.setColor(1, 0.82, 0.1, 1)
  g.rectangle("fill", bx, by, tw + pad*2, th + pad*2)
  g.setColor(0, 0, 0, 1)
  g.print(label, bx + pad, by + pad)

  if old then g.setFont(old) end
  g.pop()
end

local function drawSelectedBattleSprite(game, mon, x, y, w, h, kind)
  local resolver = spritePortraitResolver
  if not (resolver and resolver.resolve) then return false end

  local ok, img, meta = pcall(resolver.resolve, game, mon, kind)

  local badgeCode
  if resolver.debugBadge then
    local okBadge, code = pcall(resolver.debugBadge)
    if okBadge then badgeCode = code end
  end

  if not (ok and img) then
    if badgeCode and drawBattleArtDebugBadge then
      pcall(drawBattleArtDebugBadge, badgeCode, x, y, w, h)
    end
    return false
  end

  local iw, ih = img:getDimensions()
  if not iw or not ih or iw <= 0 or ih <= 0 then return false end

  local scale, dx, dy
  if type(meta) == "table"
      and meta.x0 and meta.x1 and meta.y0 and meta.y1 then
    local vw = math.max(1, meta.x1 - meta.x0 + 1)
    local vh = math.max(1, meta.y1 - meta.y0 + 1)

    -- Normalize Gen 4 portraits against their actual visible silhouette.
    -- 88% leaves breathing room comparable to the other generations while
    -- preventing large species such as Nidoking from overflowing the panel.
    local targetW, targetH = w * 0.88, h * 0.88
    scale = math.min(targetW / vw, targetH / vh)

    -- Center the visible silhouette, not the transparent source canvas.
    local visibleCX = (meta.x0 + meta.x1 + 1) * 0.5
    local visibleCY = (meta.y0 + meta.y1 + 1) * 0.5
    dx = x + w * 0.5 - visibleCX * scale
    dy = y + h * 0.5 - visibleCY * scale
  else
    scale = math.min(w / iw, h / ih)
    local dw, dh = iw * scale, ih * scale
    dx = x + (w - dw) * 0.5
    dy = y + (h - dh) * 0.5
  end

  if not scale or scale <= 0 then return false end

  love.graphics.setColor(1,1,1,1)
  local priorShader=love.graphics.getShader and love.graphics.getShader() or nil
  if type(meta)=="table" and meta.trueColor then love.graphics.setShader() end
  love.graphics.draw(img, dx, dy, 0, scale, scale)
  if type(meta)=="table" and meta.trueColor and priorShader then
    love.graphics.setShader(priorShader)
  end

  if type(meta)=="table" and meta.trueColor then
    local PaletteFX=GoldCompat.engineModule("src.render.PaletteFX")
    if PaletteFX and type(PaletteFX.markTrueColor)=="function" then
      pcall(PaletteFX.markTrueColor,dx,dy,iw*scale,ih*scale)
    end
  end

  love.graphics.setColor(1,1,1,1)

  -- Still flag it here: a fully "successful" draw can be the vanilla ROM
  -- image the resolver fell back to after Battle Art's own attempt failed
  -- (R.resolve deliberately returns that fallback rather than nothing), so
  -- from this function's perspective it looks like success even though it's
  -- exactly the symptom being reported ("falling back to default sprites").
  if badgeCode and drawBattleArtDebugBadge then
    pcall(drawBattleArtDebugBadge, badgeCode, x, y, w, h)
  end

  return true
end

local function partyLogicalCanvas()
  local sw, sh = love.graphics.getDimensions()
  local cached=GoldCompat.partyLogicalCanvasCache
  if cached and cached.sw==sw and cached.sh==sh then
    return cached.ox,cached.oy,cached.scale
  end

  local raw = math.min(sw / 160, sh / 144)

  -- Integer scaling preserves the battle font's pixel structure.
  -- Only fall back to fractional scaling on very small windows.
  local scale = math.floor(raw)
  if scale < 1 then scale = raw end

  -- The menu backplate is transparent now, so it no longer clashes with the
  -- top-right DV reader; anchor it flush to the top of the screen (no top
  -- margin) and center it horizontally.
  local m = 6
  local ox = math.floor((sw - 160*scale) * 0.5 + 0.5)
  local oy = m
  if oy < m then oy = m end
  GoldCompat.partyLogicalCanvasCache={sw=sw,sh=sh,ox=ox,oy=oy,scale=scale}
  return ox, oy, scale
end

-- FOUND (v2.1.30): v2.1.29 only lightened this panel's outer frame from
-- near-black to charcoal (0.24,0.23,0.20) -- still a fully OPAQUE filled
-- rounded-rect the same size as the card itself, so every card/row still
-- reads as a solid colored box against the overworld, just a lighter one.
-- User report against that build: "the black borders are still present...
-- there should not be two large black opaque borders on the pokemon
-- screen, it should be entirely transparent to the overworld." The ask is
-- literal: no opaque edge fill at all, just the card's own white face plus
-- a soft drop shadow and a thin outline for definition -- so the overworld
-- shows through everywhere except the face itself. Drops the charcoal fill
-- pass entirely; the shadow stays (barely visible, low alpha, offset only)
-- and a 1px outline replaces the old edge for legibility against bright
-- overworld tiles without ever being an opaque band around the card.
local function partySlotPanel(x,y,w,h,selected)
  local g = love.graphics
  g.setColor(0.05,0.07,0.06,0.30)
  roundedRect("fill",x+1.5,y+1.5,w,h,3)
  g.setColor(selected and {0.975,0.955,0.88,1} or {0.99,0.985,0.955,1})
  roundedRect("fill",x,y,w,h,3)
  g.setColor(0.30,0.29,0.26,0.80)
  roundedRect("line",x,y,w,h,3)
  if selected then
    g.setColor(0.72,0.58,0.28,1)
    roundedRect("line",x+1,y+1,w-2,h-2,2)
  end
end

local function partyHPBarFinal(x,y,w,mon)
  local g = love.graphics
  local maxhp = math.max(1, mon.stats and mon.stats.hp or 1)
  local ratio = clamp((mon.hp or 0)/maxhp,0,1)
  g.setColor(0.10,0.10,0.09,1)
  roundedRect("fill",x,y,w,4,1.5)
  g.setColor(0.78,0.76,0.63,1)
  roundedRect("fill",x+1,y+1,w-2,2,1)
  local fill = (w-2)*ratio
  if (mon.hp or 0)>0 then fill = math.max(1,fill) end
  if fill>0 then
    local r,gg,b,a = hpColor(ratio)
    g.setColor(r,gg,b,a)
    roundedRect("fill",x+1,y+1,fill,2,1)
  end
end


-- Party UI deliberately uses the exact battle typography implementation.
-- These wrappers exist only so Party layout code remains readable.
local function partyTextWidth(text, size)
  -- Convert the full-resolution battle-font width back into logical Party units
  -- so existing FRLG layout calculations (right alignment, columns) still work.
  local sc = math.max(0.001, partyRenderScale or 1)
  -- Global readability polish: a deliberately small bump, not a redesign.
  local pxSize = math.max(4, math.floor(size * sc + 0.5))
  return font(pxSize*UI_TEXT_SCALE*GoldCompat.userTextScale()):getWidth(tostring(text or "")) / sc
end

-- Same real-glyph-metrics idea as GoldCompat.bagPackRowHeight(), but
-- returning a height in the same logical Party units partyText's x/y/size
-- arguments already use, so row math (like drawPartyDetails' move rows
-- below) can be sized from what the font actually measures at the user's
-- current TEXT SIZE/TEXT THICKNESS instead of a constant sized for the
-- smallest setting. Deliberately calls the real font's :getHeight() at the
-- EXACT pxSize partyText/printText will actually render with, rather than
-- extrapolating from fontHeightPerPixel()'s single size=100 reference --
-- the first version of this helper used that extrapolation and, verified
-- against a user screenshot, came out LOWER than the true rendered glyph
-- height, so drawPartyDetails' move rows below packed tighter than the old
-- fixed-4-unit spacing did and it clipped worse than before the "fix",
-- not better. font() caches by rounded size, so this costs nothing after
-- the first call at a given size.
local function partyTextHeight(size)
  local sc = math.max(0.001, partyRenderScale or 1)
  local pxSize = math.max(4, math.floor(size * sc + 0.5))
  return font(pxSize*UI_TEXT_SCALE*GoldCompat.userTextScale()):getHeight() / sc
end

local function partyText(text, x, y, size, color, align, width)
  -- Critical difference from previous builds:
  -- Party geometry is inside a scaled 160x144 transform, but text is NOT.
  -- Drop to screen coordinates and call the exact battle printText() renderer.
  local g = love.graphics
  local sc = math.max(0.001, partyRenderScale or 1)

  local sx = math.floor((partyRenderOX or 0) + x * sc + 0.5)
  local sy = math.floor((partyRenderOY or 0) + y * sc + 0.5)
  local pxSize = math.max(4, math.floor(size * sc + 0.5))
  local pxWidth = width and math.floor(width * sc + 0.5) or nil

  g.push("all")
  g.origin()
  printText(text, sx, sy, pxSize, color, align, pxWidth)
  g.pop()
end


local function partyExpRatio(game, mon)
  if not (game and game.data and mon) then return 0 end
  local def = game.data.pokemon and game.data.pokemon[mon.species]
  if not def then return 0 end

  local cap = (game.data.constants and game.data.constants.levelCap) or 100
  local level = math.max(1, math.floor(mon.level or 1))
  if level >= cap then return 1 end

  local rates = game.data.growth_rates
  local okCur, cur = pcall(Growth.expForLevel, def.growthRate, level, rates)
  local okNext, nxt = pcall(Growth.expForLevel, def.growthRate, level + 1, rates)
  if not okCur or not okNext or not cur or not nxt or nxt <= cur then
    return 0
  end

  return clamp(((mon.exp or cur) - cur) / (nxt - cur), 0, 1)
end

function GoldCompat.drawPartyExpBar(game, mon, x, y, w)
  local g = love.graphics
  local ratio = partyExpRatio(game, mon)

  g.setColor(0.10,0.18,0.24,1)
  roundedRect("fill", x, y, w, 4, 1.5)

  g.setColor(0.14,0.28,0.38,1)
  roundedRect("fill", x+1, y+1, w-2, 2, 1)

  local fill = (w-2) * ratio
  if fill > 0 then
    g.setColor(0.08,0.48,0.96,1)
    roundedRect("fill", x+1, y+1, fill, 2, 1)
  end

  g.setColor(1,1,1,1)
end

local function partyMoveName(game, move)
  if not move then return "---" end

  local id = move.id or move.move or move.name or move
  if type(id) == "string" then
    local def = game.data.moves and game.data.moves[id]
    return (def and def.name) or id
  end

  local def = game.data.moves and game.data.moves[id]
  return (def and def.name) or tostring(id or "---")
end

local function partyMovePP(game, move)
  if not move then return "" end
  local pp = move.pp
  local maxpp = move.maxPP or move.ppMax

  if maxpp == nil then
    local id = move.id or move.move or move.name or move
    local def = game.data.moves and game.data.moves[id]
    maxpp = def and def.pp
  end

  if pp ~= nil and maxpp ~= nil then
    return tostring(pp).."/"..tostring(maxpp)
  elseif maxpp ~= nil then
    return tostring(maxpp)
  end
  return ""
end

local function partyStat(mon, ...)
  local stats = mon and mon.stats or {}
  local keys = {...}
  for _,key in ipairs(keys) do
    local v = stats[key]
    if v ~= nil then return v end
  end
  return "-"
end


function GoldCompat.drawPartyMoveReplace(game, mon, x, y, w, h, learn)
  if not (mon and learn) then return end

  local g = love.graphics
  local moves = mon.moves or {}
  local moveId = learn.newMoveId
  local newDef = moveId and game.data.moves[moveId] or nil
  local newName = (newDef and newDef.name) or tostring(moveId or "MOVE")

  -- Party geometry lives in the logical 160x144 canvas while partyText() is
  -- rendered in real screen coordinates. Keep all row/chrome geometry in the
  -- same logical transform so selection, text and separators stay locked
  -- together at every window scale.
  local function partyGeometry(fn)
    g.push("all")
    g.origin()
    g.translate(partyRenderOX or 0,partyRenderOY or 0)
    g.scale(math.max(0.001,partyRenderScale or 1),
            math.max(0.001,partyRenderScale or 1))
    fn()
    g.pop()
  end

  local areaX = x + 6
  local areaY = y + 63
  local areaW = w - 12
  local areaH = h - 67

  partyGeometry(function()
    g.setColor(0.99,0.975,0.90,1)
    g.rectangle("fill",areaX,areaY,areaW,areaH)

    g.setColor(0.70,0.68,0.59,1)
    g.rectangle("fill",x+7,y+64,w-14,1)
  end)

  partyText("REPLACE A MOVE",x+8,y+65,2.75,{0.16,0.16,0.14,1})

  -- Incoming move remains visually separate from the four replaceable rows,
  -- but is width-fitted through the same typography path rather than being
  -- truncated by character count (which was wrong for alternate fonts).
  partyText("LEARNING",x+8,y+70,1.9,{0.46,0.34,0.10,1})
  partyText(newName,x+23,y+69,2.7,{0.06,0.06,0.06,1},
    "left",math.max(8,w-31))

  -- The previous implementation sized the focus plate from an approximate
  -- row height, then rendered the move text at a fixed nominal size. With
  -- larger TEXT SIZE / alternate font profiles the REAL font line box became
  -- taller than its row, so the glyphs dropped through the selection plate
  -- and the separator lines crossed the labels. Build the four rows from the
  -- exact font metrics partyText() will use instead.
  local footerSize = 1.55
  local footerTextH = partyTextHeight(footerSize)
  local footerY = y + h - footerTextH - 1.2
  local footerDividerY = footerY - 1.2

  local moveTop = y + 75.5
  local moveBottom = footerDividerY - 0.6
  local moveBudget = math.max(8, moveBottom - moveTop)
  local rowH = moveBudget / 4

  -- Start at the established size and shrink only when the user's selected
  -- font/size genuinely cannot fit inside one quarter of the available card.
  -- partyTextHeight() includes the active font profile, UI text scale and
  -- user TEXT SIZE, so this remains responsive instead of being hard-coded
  -- for PlainPixel NORMAL.
  local moveSize = 2.05
  local minMoveSize = 1.0
  local verticalPad = math.min(1.2, math.max(0.55,rowH*0.16))
  while moveSize > minMoveSize
      and partyTextHeight(moveSize) + verticalPad > rowH do
    moveSize = moveSize - 0.10
  end
  local moveTextH = partyTextHeight(moveSize)

  local rowX = x + 7
  local rowW = w - 14
  local pointerGutter = math.max(5.5, math.min(7,rowH+1))
  local nameX = rowX + pointerGutter
  local ppRight = x + w - 7

  -- Reserve a real PP column using the active font. Move names now share one
  -- fixed left edge whether selected or not, and width-fit into the remaining
  -- lane instead of jumping horizontally when the cursor lands on them.
  local ppW = partyTextWidth("00/00",moveSize)
  for i=1,4 do
    local pp = moves[i] and partyMovePP(game,moves[i]) or ""
    if pp ~= "" then ppW=math.max(ppW,partyTextWidth(pp,moveSize)) end
  end
  local ppX = ppRight - ppW
  local nameW = math.max(8, ppX - nameX - 1.5)

  local moveCount=math.max(1,#moves)
  local selected = math.max(1,math.min(tonumber(learn.index) or 1,moveCount))

  for i=1,4 do
    local mv = moves[i]
    local my = moveTop + (i-1)*rowH
    local isSelected = (i == selected)
    local boxInset = math.min(0.45,rowH*0.07)
    local boxY = my + boxInset
    local boxH = math.max(1,rowH-boxInset*2)
    local textY = my + math.max(0,(rowH-moveTextH)*0.5)

    partyGeometry(function()
      if isSelected then
        g.setColor(0.10,0.10,0.09,1)
        roundedRect("fill",rowX,boxY,rowW,boxH,
          math.min(1.2,boxH*0.22))

        -- Warm selection rail plus a geometry cursor. The old ">" was a font
        -- glyph, so its baseline moved independently from the row and became a
        -- clipped orange blob with some font/size combinations.
        g.setColor(0.92,0.47,0.13,1)
        local railW=math.max(1.3,math.min(2.1,rowH*0.32))
        roundedRect("fill",rowX+0.8,boxY+0.55,railW,
          math.max(0.8,boxH-1.1),0.6)

        local cy=boxY+boxH*0.5
        local ah=math.max(0.8,math.min(1.45,boxH*0.26))
        local aw=math.max(0.8,math.min(1.45,boxH*0.24))
        local ax=rowX+3.6
        g.polygon("fill",ax,cy-ah,ax+aw,cy,ax,cy+ah)
      else
        g.setColor(0.78,0.76,0.67,0.58)
        g.rectangle("fill",rowX+3,my+rowH-0.35,rowW-6,0.45)
      end
    end)

    local col = isSelected and {1,1,1,1} or {0.06,0.06,0.06,1}
    local ppCol = isSelected and {1,1,1,1} or {0.20,0.20,0.18,1}

    if mv then
      local name = partyMoveName(game,mv)
      partyText(name,nameX,textY,moveSize,col,"left",nameW)

      local pp = partyMovePP(game,mv)
      if pp ~= "" then
        partyText(pp,ppX,textY,moveSize,ppCol,"right",ppW)
      end
    else
      partyText("---",nameX,textY,moveSize,
        isSelected and {1,1,1,1} or {0.38,0.38,0.34,1},
        "left",nameW)
    end
  end

  partyGeometry(function()
    g.setColor(0.86,0.84,0.75,1)
    g.rectangle("fill",x+8,footerDividerY,w-16,0.6)
  end)
  partyText("A REPLACE   B CANCEL",x+9,footerY,footerSize,
    {0.28,0.28,0.25,1},"left",math.max(8,w-18))
  g.setColor(1,1,1,1)
end


local function drawPartyDetails(game, mon, x, y, w, h)
  if not mon then return end

  local g = love.graphics
  local moves = mon.moves or {}

  -- Details begin directly under EXP.
  local detailDividerY = y + 64
  g.setColor(0.70,0.68,0.59,1)
  g.rectangle("fill", x+7, detailDividerY, w-14, 1)

  -- Stats stay in a fixed footer, isolated from moves.
  local statsDividerY = y + h - 13

  -- v2.1.24 switched this budget check from an extrapolated height guess to
  -- the font's real measured getHeight() -- correct in principle (the same
  -- fix already proven for GoldCompat.bagPackRowHeight), but never actually
  -- re-checked against what that real number turns out to BE for this exact
  -- font asset. Measured directly (assets/fonts/plainpixel/PlainPixel-
  -- Regular.ttf, PIL freetype getmetrics): getHeight() runs roughly 1.9-2.0x
  -- the nominal size passed to love.graphics.newFont, not the ~1.2x a normal
  -- text font would suggest. Fed into the OLD budget math (a "MOVES" header
  -- row plus a 2-unit gap after every one of the 4 rows, all squeezed into
  -- this card's fixed ~21-logical-unit gap between the EXP divider and the
  -- stats footer), solving for the largest row size that still fits comes
  -- out BELOW the loop's old 1.4 floor even at the DEFAULT "normal" TEXT
  -- SIZE setting -- so the search always ran all the way down to that floor
  -- and STILL didn't fit: the 4th move row kept spilling into ATK/DEF/SPD/SPC
  -- exactly as reported, while the header and rows were also shrunk to the
  -- smallest, least legible size for nothing, which is what actually made
  -- v2.1.24 look WORSE than v2.1.23 despite fixing the metric itself.
  -- Fixed by reclaiming real space instead of re-tuning the same too-tight
  -- budget a third time: the "MOVES" label added a whole extra text row's
  -- worth of height to a budget that can't afford one (the 4 move rows
  -- themselves already make it obvious what this section is, right under
  -- the EXP divider), and the per-row gap after each row only needs to be
  -- wide enough to visually separate rows, not a full 2 units. Re-solving
  -- with the real 1.9-2.0x ratio confirms this fits at every TEXT SIZE
  -- setting (small/normal/large/x-large) without ever needing the floor.
  local budget = statsDividerY - detailDividerY - 1
  local rowGap = 1
  local rowSize = 3
  while rowSize > 1.3 and 4*(partyTextHeight(rowSize)+rowGap) > budget do
    rowSize = rowSize - 0.2
  end
  local ppSize = math.max(1.2, rowSize - 1)

  local moveTop = detailDividerY + 1
  local moveRowH = partyTextHeight(rowSize) + rowGap
  local ppRight = x + w - 7

  for i=1,4 do
    local m = moves[i]
    local my = moveTop + (i-1)*moveRowH
    local name = partyMoveName(game,m)
    local pp = partyMovePP(game,m)

    -- Truncate by real measured width, not a fixed character count -- a
    -- bold/x-large font can overflow (or a thin/small one waste) space a
    -- fixed 12-character cutoff never accounted for, and the move name must
    -- still clear the PP column that sits to its right.
    local pw = pp ~= "" and partyTextWidth(pp, ppSize) or 0
    local nameMaxW = (ppRight - (pp ~= "" and (pw + 3) or 0)) - (x + 8)
    while #name > 1 and partyTextWidth(name, rowSize) > nameMaxW do
      name = name:sub(1, #name - 2).."."
    end

    partyText(name, x+8, my, rowSize, {0.06,0.06,0.06,1})

    if pp ~= "" then
      partyText(pp, ppRight-pw, my, ppSize, {0.20,0.20,0.18,1})
    end
  end
  g.setColor(0.74,0.72,0.64,1)
  g.rectangle("fill", x+7, statsDividerY, w-14, 1)

  local stats = {
    {"ATK", partyStat(mon,"attack","atk")},
    {"DEF", partyStat(mon,"defense","def")},
    {"SPD", partyStat(mon,"speed","spd")},
    {"SPC", partyStat(mon,"special","spc","specialAttack")},
  }

  local innerX = x + 7
  local innerW = w - 14
  local colW = innerW / 4
  local labelY = statsDividerY + 1
  local valueY = statsDividerY + 4

  for i,s in ipairs(stats) do
    local colX = innerX + (i-1)*colW
    local label = s[1]
    local value = tostring(s[2])

    local lw = partyTextWidth(label, 2)
    local vw = partyTextWidth(value, 3)

    partyText(label, colX + (colW-lw)/2, labelY, 2, {0.25,0.25,0.22,1})
    partyText(value, colX + (colW-vw)/2, valueY, 3, {0.06,0.06,0.06,1})
  end
end


local function pokedexSeenCount(save)
  -- Gen1Recomp's authoritative Pokédex save structure is:
  --   save.pokedex.seen
  --   save.pokedex.owned
  -- The UI should mirror the game's actual Pokédex flags directly rather than
  -- infer progress from party/storage contents or alternate field names.
  local seen=save and save.pokedex and save.pokedex.seen
  if type(seen)~="table" then return 0 end

  local count=0
  for _ in pairs(seen) do
    count=count+1
  end
  return count
end

local function pokedexOwnedCount(save)
  local owned=save and save.pokedex and save.pokedex.owned
  if type(owned)~="table" then return 0 end
  local count=0
  for _ in pairs(owned) do count=count+1 end
  return count
end

function GoldCompat.totalStoredPokemon(save)
  if not save then return 0 end

  -- Prefer the canonical Boxes container when available, but remain
  -- defensive for save-format/mod variations.
  local boxes=save.boxes
      or save.pcBoxes
      or save.storage
      or save.pokemonBoxes

  if type(boxes)=="table" then
    local total=0
    for _,box in pairs(boxes) do
      if type(box)=="table" then
        -- Some formats wrap entries under .pokemon/.mons/.slots.
        local entries=box.pokemon or box.mons or box.slots or box
        if type(entries)=="table" then
          for _,mon in pairs(entries) do
            if type(mon)=="table" and (mon.species or mon.nickname or mon.level) then
              total=total+1
            end
          end
        end
      end
    end
    return total
  end

  -- Last-resort: current active box only, better than showing nonsense.
  local ok,active=pcall(Boxes.active,save)
  if ok and type(active)=="table" then return #active end

  return 0
end

function GoldCompat.pcSelectedMon(game,state)
  if not state then return nil end

  if state.__gen3uiPCList then
    -- Gen 1's real kind values (see the ListMenu.new patch in
    -- installPCIntegration) are exact and generation-clean -- check them
    -- first, ahead of the Gen 2 title-string heuristics below, which Gen 1
    -- can never match (its real BoxMenu.lua always pushes these with
    -- title=nil).
    local kind=tostring(state.kind or "")
    local title=tostring(state.title or ""):upper()
    local source=nil
    if kind=="pc_box_deposit" then
      source=game.save and game.save.party or {}
    elseif kind=="pc_box_withdraw" or kind=="pc_box_release" then
      source=Boxes.active(game.save)
    elseif title=="PARTY (DEPOSIT)" then
      source=game.save and game.save.party or {}
    elseif title:find("(WITHDRAW)",1,true) or title:find("(RELEASE)",1,true) then
      source=Boxes.active(game.save)
    end
    if source then
      local index=math.max(1,math.min(state.index or 1,#source))
      return source[index]
    end
  end

  return nil
end

local function drawPCBackground(game,title,subtitle)
  local g=love.graphics
  g.setColor(0.94,0.93,0.87,1)
  g.rectangle("fill",0,0,160,144)

  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,4,152,16)
  g.setColor(0.99,0.985,0.955,1)
  g.rectangle("fill",5,5,150,14)
  partyText(title or "POKéMON PC",10,6,6,{0.06,0.06,0.06,1})

  if subtitle and subtitle~="" then
    local tw=partyTextWidth(subtitle,3)
    partyText(subtitle,151-tw,9,3,{0.26,0.26,0.23,1})
  end
end

local function drawPCAccessFinal(game,state)
  local ox,oy,sc=partyLogicalCanvas()
  local g=love.graphics
  partyRenderOX,partyRenderOY,partyRenderScale=ox,oy,sc

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  local items=state.items or {}
  local count=#items
  local w=64
  local h=10+count*14
  local x=92
  local y=10

  g.setColor(0.08,0.08,0.08,0.35)
  roundedRect("fill",x+2,y+2,w,h,3)
  g.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x,y,w,h,3)
  g.setColor(0.12,0.12,0.11,1)
  g.setLineWidth(1.5)
  roundedRect("line",x,y,w,h,3)

  for i,item in ipairs(items) do
    local yy=y+6+(i-1)*14
    local selected=i==(state.index or 1)
    if selected then
      g.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",x+5,yy-1,w-10,10,2)
      g.setColor(0.72,0.58,0.30,1)
      roundedRect("line",x+6,yy,w-12,8,2)
    end
    local label=tostring(item.label or ""):gsub("<PK><MN>","POKéMON")
    partyText(label,x+10,yy,4,
      selected and {0.98,0.97,0.92,1} or {0.06,0.06,0.06,1})
  end

  local bx,by,bw,bh=4,118,152,22
  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",bx,by,bw,bh)
  g.setColor(0.99,0.985,0.95,1)
  g.rectangle("fill",bx+2,by+2,bw-4,bh-4)
  drawUnifiedBorder(bx,by,bw,bh,0)
  partyText("Access whose PC?",bx+7,by+7,4,{0.05,0.05,0.05,1})

  g.pop()
end

local function drawPCMainFinal(game,state)
  local ox,oy,sc=partyLogicalCanvas()
  local g=love.graphics
  partyRenderOX,partyRenderOY,partyRenderScale=ox,oy,sc

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  local box=Boxes.active(game.save)
  drawPCBackground(game,"POKéMON PC",
    ("BOX %d   %d/%d"):format(game.save.currentBox or 1,#box,Boxes.CAPACITY))

  -- Left information panel mirrors the selected-Pokémon menu's visual frame.
  local lx,ly,lw,lh=4,23,72,96
  partySlotPanel(lx,ly,lw,lh,true)
  partyText("STORAGE",lx+7,ly+6,5,{0.06,0.06,0.06,1})
  partyText(("BOX %d"):format(game.save.currentBox or 1),lx+7,ly+18,6,
    {0.06,0.06,0.06,1})
  partyText(("%d / %d POKéMON"):format(#box,Boxes.CAPACITY),
    lx+7,ly+29,4,{0.18,0.18,0.16,1})
  partyText(("PARTY  %d / 6"):format(#(game.save.party or {})),
    lx+7,ly+37,4,{0.18,0.18,0.16,1})

  -- At-a-glance storage summary. The action list already exists on the right,
  -- so this space is more useful for persistent player/storage information.
  local seenCount=pokedexSeenCount(game.save)
  local ownedCount=pokedexOwnedCount(game.save)
  local pcTotal=GoldCompat.totalStoredPokemon(game.save)

  partyText("POKéDEX",lx+7,ly+52,3,{0.30,0.28,0.22,1})
  partyText(tostring(seenCount).." SEEN",lx+9,ly+59,4.4,{0.08,0.08,0.08,1})
  partyText(tostring(ownedCount).." OWNED",lx+36,ly+59,4.4,{0.08,0.08,0.08,1})

  partyText("TOTAL IN PC",lx+7,ly+72,3,{0.30,0.28,0.22,1})
  partyText(tostring(pcTotal).." POKéMON",lx+9,ly+79,5,{0.08,0.08,0.08,1})

  -- Right action list.
  local rx,ry,rw,rh=80,23,76,96
  partySlotPanel(rx,ry,rw,rh,false)
  local items=state.items or {}
  -- Row label draws at 3 below -- dynamic to match TEXT SIZE (General
  -- Sweep, v2.1.28), shrinking back down (same pattern as the party card's
  -- MOVES list/move-replace panel) since this action list sits in the
  -- same fixed-size right-hand panel regardless of how many rows it holds.
  local rowH=GoldCompat.dynamicRowHeight(3,10,3)
  local rowBudget=rh-10
  while rowH>8 and #items*rowH>rowBudget do
    rowH=rowH-1
  end
  local highlightH=math.max(6,rowH-3)
  local lineH=math.max(4,highlightH-2)
  for i,item in ipairs(items) do
    local y=ry+5+(i-1)*rowH
    local selected=i==(state.index or 1)
    if selected then
      g.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",rx+4,y-1,rw-8,highlightH,2)
      g.setColor(0.62,0.48,0.20,1)
      roundedRect("line",rx+5,y,rw-10,lineH,2)
    end
    local label=tostring(item.label or "")
      :gsub("<PK><MN>","POKéMON")
    partyText(label,rx+8,y,3,
      selected and {0.98,0.97,0.92,1} or {0.06,0.06,0.06,1})
  end

  -- Footer follows the same dark instruction strip as Party.
  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,127,152,13)
  partyText("Choose a PC action.",9,129,4,{0.98,0.98,0.96,1})

  g.pop()
end

local function drawPCListFinal(game,state)
  local ox,oy,sc=partyLogicalCanvas()
  local g=love.graphics
  partyRenderOX,partyRenderOY,partyRenderScale=ox,oy,sc

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  local title=tostring(state.title or "POKéMON PC")
  drawPCBackground(game,title,
    ("BOX %d"):format(game.save.currentBox or 1))

  local mon=GoldCompat.pcSelectedMon(game,state)
  local lx,ly,lw,lh=4,23,69,101
  partySlotPanel(lx,ly,lw,lh,true)

  if mon then
    local def=game.data.pokemon[mon.species]
    local name=mon.nickname or (def and def.name) or "POKéMON"
    partyText(name,lx+7,ly+5,6,{0.06,0.06,0.06,1})

    local lv="Lv."..tostring(mon.level or "?")
    local lvw=partyTextWidth(lv,5)
    partyText(lv,lx+lw-7-lvw,ly+6,5,{0.06,0.06,0.06,1})

    local drew=drawSelectedBattleSprite(game,mon,lx+8,ly+16,30,27,"pc")
    if not drew then
      PartyMenu.drawIcon(game,mon,lx+7,ly+19,true,state.blink or 0)
    end

    -- Box Pokémon can have incomplete stats; keep details defensive.
    local maxhp=mon.stats and mon.stats.hp
    if maxhp then
      local hp=("%d/%d"):format(mon.hp or 0,math.max(1,maxhp))
      local hpw=partyTextWidth(hp,4)
      local hpX=lx+lw-7-hpw
      partyText("HP",lx+9,ly+44,4,{0.08,0.08,0.08,1})
      partyHPBarFinal(lx+21,ly+45,math.max(18,hpX-(lx+21)-3),mon)
      partyText(hp,hpX,ly+44,4,{0.08,0.08,0.08,1})
    else
      partyText("STORED POKéMON",lx+9,ly+45,3,{0.28,0.28,0.24,1})
    end

    drawPartyDetails(game,mon,lx,ly,lw,lh)
  else
    partyText("NO POKéMON",lx+16,ly+46,5,{0.25,0.25,0.22,1})
  end

  -- Right storage/party list uses the Party slot language.
  local items=state.items or {}
  local rx,rw=77,79
  local selectedIndex=math.max(1,math.min(state.index or 1,math.max(1,#items)))

  -- The native ListMenu selection can move beyond the first six entries while
  -- some versions/mod stacks leave state.scroll unchanged. Derive the visible
  -- six-row window directly from the live selection so the right panel always
  -- scrolls with the cursor.
  local firstVisible=1
  if selectedIndex>6 then
    firstVisible=selectedIndex-5
  end
  if #items>6 then
    firstVisible=math.min(firstVisible,#items-5)
  end
  firstVisible=math.max(1,firstVisible)

  for row=1,6 do
    local itemIndex=firstVisible+row-1
    local item=items[itemIndex]
    local y=23+(row-1)*17
    if item then
      local selected=itemIndex==selectedIndex
      partySlotPanel(rx,y,rw,16,selected)
      local label=tostring(item.label or "")
      partyText(label,rx+7,y+3,3,
        {0.06,0.06,0.06,1},"left",rw-14)
    else
      partySlotPanel(rx,y,rw,16,false)
    end
  end

  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,127,152,13)
  local kind=tostring(state.kind or "")
  local up=tostring(state.title or ""):upper()
  local footer="Choose a POKéMON."
  if kind=="pc_box_withdraw" or up:find("WITHDRAW",1,true) then
    footer="Withdraw which POKéMON?"
  elseif kind=="pc_box_deposit" or up:find("DEPOSIT",1,true) then
    footer="Deposit which POKéMON?"
  elseif kind=="pc_box_release" or up:find("RELEASE",1,true) then
    footer="Release which POKéMON?"
  elseif up=="CHANGE BOX" then
    footer="Choose a BOX."
  end
  partyText(footer,9,129,4,{0.98,0.98,0.96,1},"left",142)

  g.pop()
end

local function drawPCActionFinal(game,state)
  -- Preserve the PC list underneath, then draw a compact themed action card.
  local under=nil
  if game and game.stack and game.stack.states then
    for i=#game.stack.states-1,1,-1 do
      local s=game.stack.states[i]
      if s and s.__gen3uiPCList then under=s break end
    end
  end
  if under then drawPCListFinal(game,under) end

  local ox,oy,sc=partyLogicalCanvas()
  local g=love.graphics
  partyRenderOX,partyRenderOY,partyRenderScale=ox,oy,sc
  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  local x,y,w=105,74,48
  local items=state.items or {}
  local h=8+#items*12
  partySlotPanel(x,y,w,h,true)
  for i,item in ipairs(items) do
    local yy=y+5+(i-1)*12
    local selected=i==(state.index or 1)
    if selected then
      g.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",x+4,yy-1,w-8,9,2)
    end
    partyText(tostring(item.label or ""),x+8,yy,3,
      selected and {0.98,0.97,0.92,1} or {0.06,0.06,0.06,1})
  end
  g.pop()
end

local function drawPartyFinal(game, state)
  local party = state.party or (game.save and game.save.party) or {}
  local ox,oy,sc = partyLogicalCanvas()
  local g = love.graphics

  -- Text helpers use these to escape the logical transform and render with
  -- battle-quality typography directly in final screen pixels.
  partyRenderOX, partyRenderOY, partyRenderScale = ox, oy, sc

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  -- No full-canvas backplate: keep the menu transparent so overlays such as
  -- the DV reader show through. Only the individual Pokémon cards paint a
  -- beige panel (see partySlotPanel below).

  -- Header title only (no black/cream frame box around it).
  partyText(Strings("POKéMON"),10,6,6,{0.06,0.06,0.06,1})

  if #party == 0 then
    GoldCompat.owText(Strings("No POKéMON!"),12,62,10,{0.06,0.06,0.06,1})
    g.pop()
    return
  end

  local selected = clamp(state.index or 1,1,#party)
  local mon = party[selected]
  local def = mon and game.data.pokemon[mon.species]

  -- Large selected detail panel on left.
  local lx,ly,lw,lh = 4,23,74,101
  partySlotPanel(lx,ly,lw,lh,true)

  if mon then
    -- Large selected portrait uses the active FRONT battle sprite. The six
    -- party entries on the right intentionally remain standard menu icons.
    local drewBattlePortrait = drawSelectedBattleSprite(
      game, mon,
      lx+7, ly+15,
      31, 27,
      "summary"
    )
    if not drewBattlePortrait then
      -- Defensive fallback for a missing/invalid battle asset.
      PartyMenu.drawIcon(game,mon,lx+6,ly+18,true,state.blink or 0)
    end


    local name = mon.nickname or (def and def.name) or "POKéMON"
    partyText(name,lx+7,ly+5,6,{0.06,0.06,0.06,1})

    local lv = "Lv."..tostring(mon.level or "?")
    local lvw = partyTextWidth(lv,5)
    partyText(lv,lx+lw-7-lvw,ly+6,5,{0.06,0.06,0.06,1})

    -- HP mirrors the EXP row's visual rhythm, but reserves a right-side
    -- value slot so current/max HP stays on the same line as the bar.
    local hpY = ly + 43
    local hpLabelX = lx + 9
    local hpBarX = lx + 21

    local hp = ("%d/%d"):format(mon.hp or 0,
      math.max(1,mon.stats and mon.stats.hp or 1))
    local hpw = partyTextWidth(hp,4)
    local hpValueX = lx + lw - 7 - hpw
    local hpBarW = math.max(18, hpValueX - hpBarX - 3)

    partyText("HP",hpLabelX,hpY,4,{0.08,0.08,0.08,1})
    partyHPBarFinal(hpBarX,hpY+1,hpBarW,mon)
    partyText(hp,hpValueX,hpY,4,{0.08,0.08,0.08,1})

    local st = owStatus(mon)
    if st then
      partyText(st,lx+9,ly+51,4,
        st=="FNT" and {0.52,0.10,0.08,1} or {0.40,0.15,0.44,1})
    end

    -- Live Party EXP, matching the battle HUD's blue language.
    partyText("EXP",lx+9,ly+58,3,{0.34,0.45,0.50,1})
    GoldCompat.drawPartyExpBar(game,mon,lx+21,ly+59,lw-29)

    local integratedLearn = State.activeMoveLearn
    local battleIntegrated =
      State.activeBattleMoveLearn
      and State.activeBattleMoveLearn.selecting
      and State.activeBattleMoveLearn.mon == mon
      and state.__gen3uiBattleMoveParty

    if battleIntegrated then
      integratedLearn=State.activeBattleMoveLearn
    end

    if integratedLearn and integratedLearn.selecting
        and integratedLearn.mon == mon
        and (battleIntegrated or canIntegrateMoveLearn(game, integratedLearn)) then
      GoldCompat.drawPartyMoveReplace(game,mon,lx,ly,lw,lh,integratedLearn)
    else
      drawPartyDetails(game,mon,lx,ly,lw,lh)
    end
  end

  -- All six Pokémon are always listed on the right, including the selected one.
  local rx,rw = 80,76
  local slotH,gap = 16,1
  for i,m in ipairs(party) do
    if i > 6 then break end
    local y = 23 + (i-1)*(slotH+gap)
    local isSelected = i == selected
    local d = game.data.pokemon[m.species]

    -- Selected row gets dark highlight, others stay light.
    if isSelected then
      g.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",rx,y,rw,slotH,3)
      g.setColor(0.985,0.975,0.92,1)
      roundedRect("fill",rx+2,y+2,rw-4,slotH-4,2)
      -- Party screen is intentionally theme-locked.
      g.setColor(0.62,0.48,0.20,1)
      roundedRect("line",rx+3,y+3,rw-6,slotH-6,2)
      g.setColor(1,1,1,1)
    else
      partySlotPanel(rx,y,rw,slotH,false)
    end

    local drewRowPortrait=false
    if not m.isEgg then
      drewRowPortrait=GoldCompat.drawCleanResolvedPortrait(game,m,
        ox+(rx+3)*sc,oy+(y+1)*sc,14*sc,14*sc,"summary")
    end
    if not drewRowPortrait then
      PartyMenu.drawIcon(game,m,rx+2,y,false,state.blink or 0)
    end

    local name = m.nickname or (d and d.name) or "POKéMON"
    partyText(name,rx+19,y+1,4,{0.06,0.06,0.06,1})

    local lv = "Lv."..tostring(m.level or "?")
    local lvw = partyTextWidth(lv,5)
    partyText(lv,rx+rw-4-lvw,y+1,4,{0.06,0.06,0.06,1})

    if state.tmhm then
      local canLearn = false
      local monDef = game.data.pokemon[m.species]
      for _,moveId in ipairs((monDef and monDef.tmhm) or {}) do
        if moveId == state.tmhm.move then
          canLearn = true
          break
        end
      end

      local ableText = canLearn and "ABLE" or "NOT ABLE"
      local ableW = partyTextWidth(ableText,3)
      partyText(ableText,rx+rw-5-ableW,y+8,3,
        canLearn and {0.16,0.42,0.20,1} or {0.46,0.14,0.12,1})

    elseif state.__gen3uiItemTarget and itemTargetIsStone(state) then
      local allowed=GoldCompat.stoneAllowedForMon(game,state,m)
      local allowedText=allowed and "ALLOWED" or "NOT ALLOWED"
      local allowedW=partyTextWidth(allowedText,3)
      partyText(allowedText,rx+rw-5-allowedW,y+8,3,
        allowed and {0.16,0.42,0.20,1} or {0.46,0.14,0.12,1})

    else
      partyText("HP",rx+19,y+8,3,{0.10,0.10,0.09,1})
      partyHPBarFinal(rx+31,y+10,rw-35,m)
    end
  end

  -- Bottom prompt.
  g.setColor(0.10,0.10,0.10,1)
  g.rectangle("fill",4,127,152,13)
  local prompt
  local promptLearn=State.activeMoveLearn
  local promptIntegrated=promptLearn and promptLearn.selecting
      and canIntegrateMoveLearn(game,promptLearn)

  if state.__gen3uiBattleMoveParty
      and State.activeBattleMoveLearn
      and State.activeBattleMoveLearn.selecting then
    promptLearn=State.activeBattleMoveLearn
    promptIntegrated=true
  end

  if promptLearn and promptIntegrated then
    local moveId = promptLearn.newMoveId
    local nd = moveId and game.data.moves[moveId] or nil
    local nn = (nd and nd.name) or tostring(moveId or "MOVE")
    local moveCount = #(promptLearn.mon and promptLearn.mon.moves or {})
    if (promptLearn.index or 1) > moveCount then
      prompt = "CANCEL"
    else
      prompt = "Choose move to replace with "..nn.."."
    end
  elseif state.__gen3uiItemTarget and itemTargetIsStone(state) then
    prompt = "Use stone on which POKéMON?"
  elseif state.__gen3uiItemTarget then
    prompt = "Use item on which POKéMON?"
  else
    prompt = tostring(state:bottomMessage() or ""):gsub("\n"," ")
  end
  partyText(prompt,9,129,6,{1,1,1,1})

  -- Existing submenu.
  if state.submenu and state.subItems then
    local count=#state.subItems
    -- FOUND: row pitch (12) and the selection highlight's height (11) were
    -- fixed constants sized for the default TEXT SIZE, while the label
    -- itself (partyText's size=6, drawn at a fixed yy+1) grows with the
    -- user's TEXT SIZE/TEXT THICKNESS settings via UI_TEXT_SCALE/
    -- userTextScale(). At anything but the smallest setting the label's
    -- real glyph height no longer matched that guessed 11px band, so the
    -- fixed yy+1 offset landed the text near the TOP of the highlight with
    -- a growing dead gap underneath -- the exact same class of bug already
    -- fixed for the Bag/Pack list (see GoldCompat.bagPackRowHeight) by
    -- deriving row pitch from the label's actual measured font height
    -- instead of a constant. Reusing that same real-metric helper here
    -- keeps this submenu's row height and its label's vertical placement
    -- consistent with each other regardless of label text or TEXT SIZE/
    -- THICKNESS -- rather than only "usually close enough".
    local rowH=GoldCompat.dynamicRowHeight(6,12,3)
    local highlightH=rowH-1
    local sw=62
    local sh=6+count*rowH
    local sx=160-sw-5
    local sy=math.max(5,124-sh)
    GoldCompat.frlgMenuPanel(sx,sy,sw,sh)

    for si,entry in ipairs(state.subItems) do
      local yy=sy+4+(si-1)*rowH
      if si==state.subIndex then
        GoldCompat.frlgSelection(sx+3,yy,sw-6,highlightH)
        partyText(entry.label,sx+8,yy+1,6,{1,1,1,1})
      else
        partyText(entry.label,sx+8,yy+1,6,{0.06,0.06,0.06,1})
      end
    end
  end

  g.setColor(1,1,1,1)
  g.pop()
end

-- -------------------------------------------------------------------------

-- -------------------------------------------------------------------------
-- Final-HUD themed dialogue / choice overlay
-- -------------------------------------------------------------------------

function GoldCompat.dialogueVisibleText(box, shownIndex)
  local shown = box.shown and box.shown[shownIndex]
  if not shown then return "" end

  local page = box.pages and box.pages[box.pageIndex]
  if not page then return "" end

  local sourceIndex = box.lineIndex - (#box.shown - shownIndex)
  local source = page[sourceIndex] or ""
  local spans = EngineFont.split(source)

  local count = math.min(#shown, #spans)
  if count <= 0 then return "" end
  return source:sub(1, spans[count].to)
end


-- Gen 1 SAVE is not a TextBox-owned info panel: StartMenu draws the summary
-- directly and only the later confirmation uses TextBox/ChoiceBox. The old
-- page-content detector could therefore never match and has been removed;
-- installGen1SaveScreen tags the real pushed save panel instead.
-- The real save-panel renderer reads game.save directly. The later YES/NO
-- confirmation continues through the normal themed dialogue path.
function GoldCompat.drawGen1SavePanelFinal(game,state)
  local save=game and game.save
  if not save then return false end
  local g=love.graphics
  local sw,sh=g.getDimensions()
  local sc=math.max(1,sh/144)
  local x=math.floor(sw-81*sc)
  local y=math.floor(18*sc)
  local w=math.floor(76*sc)
  local h=math.floor(68*sc)

  g.push("all")
  g.origin()
  g.setColor(0.04,0.04,0.04,0.30)
  roundedRect("fill",x+2*sc,y+2*sc,w,h,4*sc)
  g.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",x,y,w,h,4*sc)
  g.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+2*sc,y+2*sc,w-4*sc,h-4*sc,3*sc)
  g.setColor(0.11,0.28,0.38,1)
  roundedRect("fill",x+5*sc,y+5*sc,w-10*sc,14*sc,2*sc)
  g.pop()

  local badges=0
  local Badges=GoldCompat.engineModule("src.inventory.Badges")
  if Badges and type(Badges.count)=="function" then
    local ok,count=pcall(Badges.count,game.data,save)
    if ok then badges=tonumber(count) or 0 end
  end
  local caught=0
  for _ in pairs(save.pokedex and save.pokedex.owned or {}) do caught=caught+1 end
  local t=math.floor(save.playTime or 0)

  printText("SAVE",x+8*sc,y+9*sc,4.3*sc,{1,1,1,1})
  local dark={0.08,0.08,0.08,1}
  local muted={0.38,0.38,0.35,1}
  local function row(label,value,yy)
    printText(label,x+8*sc,y+yy*sc,2.35*sc,muted)
    printText(tostring(value),x+34*sc,y+yy*sc,2.8*sc,dark,"left",34*sc)
  end
  row("PLAYER",save.player and save.player.name or "RED",27)
  row("BADGES",badges,38)
  row("POKéDEX",caught,49)
  row("TIME",("%d:%02d"):format(math.floor(t/3600),math.floor(t/60)%60),60)
  return true
end

function GoldCompat.drawDialogueThemeFinal(box)
  local g = love.graphics
  local sw,sh = g.getDimensions()
  local sc = math.max(1,sh/144)
  local margin = math.floor(4*sc+0.5)
  -- Native TextBox dialogue follows the same adaptive sizing contract as
  -- battle dialogue. Large text gains height instead of crossing the scissor.
  local _,heightScale=GoldCompat.dialogueLayoutScale()
  -- FOUND: user report -- Gen2's TM/HM "forget a move" flow (State.activeGen2MoveLearn)
  -- keeps the underlying "Which move should be forgotten?" TextBox open the
  -- WHOLE time the player is choosing (Game2:learnMoveOn's pickMove() pushes
  -- it with stay=true and never pops it until the choice is made), while the
  -- restyled party card's REPLACE MOVE row list is drawn UNDERNEATH it in the
  -- very same bottom slice of the screen (drawPartyFinal's card occupies
  -- ly=23..124 of the 144-tall logical canvas; this box's normal height
  -- range of 24-42 anchored to the bottom lands its top edge at y=98-116,
  -- squarely inside the card's own move-row band). The result: the box
  -- visually buries the very rows the player needs to read to make their
  -- choice, for both Gen 1's MoveLearnMenu integration (State.activeTMPromptFlow)
  -- and Gen 2's. The paging renderer below already only ever shows 2 lines
  -- at a time regardless of box height (visible=math.min(2,#shown)), so a
  -- short, fixed compact height loses no content here -- it only forces a
  -- smaller, auto-fitted font via the same fittedCompletedDialogue sizing
  -- already used below. Sized so its top edge sits right at the card's own
  -- bottom edge (124) instead of climbing into it.
  -- Only compact the dialogue while the player is ACTUALLY choosing a move.
  -- activeGen2MoveLearn intentionally spans the entire teach chain, including
  -- the later "1, 2 and… Poof! / forgot / learned" pages. Treating that
  -- whole lifetime as a selection state crushed those normal multi-page
  -- messages into the tiny 16px strip and visibly clipped/truncated them.
  local compactForMoveLearn =
      (State.activeTMPromptFlow and State.activeTMPromptFlow.selecting)
      or State.activeGen2MoveDeleter~=nil
  local logicalH
  if compactForMoveLearn then
    logicalH = 16
  else
    logicalH=math.max(24,math.min(42,24*heightScale))
  end
  local h = math.floor(logicalH*sc+0.5)
  local x = margin
  local y = sh-h-margin
  local w = sw-margin*2

  g.push("all")
  g.origin()

  g.setColor(0.04,0.04,0.04,0.30)
  g.rectangle("fill",x+2*sc,y+2*sc,w,h)
  g.setColor(0.08,0.08,0.07,1)
  g.rectangle("fill",x,y,w,h)
  g.setColor(0.99,0.985,0.95,1)
  g.rectangle("fill",x+2*sc,y+2*sc,w-4*sc,h-4*sc)
  drawUnifiedBorder(x,y,w,h,0)

  local off = box.scrollPx or 0
  local preferred = math.max(14,math.floor(6.2*sc+0.5))
  local minimum = math.max(9,math.floor(preferred*0.56+0.5))
  local textX = math.floor(x+7*sc+0.5)
  local contentW = math.max(1,math.floor(w-14*sc+0.5))
  local shown = box.shown or {}
  local visible = math.min(2,#shown)

  local textGrowth=math.max(0,GoldCompat.userTextScale()-1)
  local innerTop=math.max(3,math.floor((3+textGrowth*2)*sc+0.5))
  local innerBottom=math.max(4,math.floor((4+textGrowth*2)*sc+0.5))
  local innerH=math.max(1,h-innerTop-innerBottom)

  local pageComplete = box.waiting
    or (box.done and not box.choice and not box.auto and not box.stay)

  -- FOUND: this only ever drew box.pages' native pre-wrapped lines verbatim
  -- (via dialogueVisibleText) and picked a font size that fit THOSE narrow
  -- native lines (fittedDialogueMetrics). Native wraps each page for its own
  -- original, much narrower box -- drawing those exact line breaks inside
  -- this mod's wider restyled box is why dialogue looked left-heavy with a
  -- lot of empty space on the right, regardless of text/font size settings.
  -- Once a page has finished typing, re-wrap its FULL text against the
  -- actual width of the box being drawn and pick the best-fitting size for
  -- THAT layout -- the same technique GoldCompat.fittedCompletedDialogue
  -- already uses successfully for battle dialogue. While a page is still
  -- typing, native's own line-by-line reveal is kept (re-flowing mid-type
  -- would make characters jump between lines as they're revealed), sized to
  -- match what the page will look like once it snaps to the reflowed layout.
  local page = box.pages and box.pages[box.pageIndex]
  local fullLines = {}
  if type(page)=="table" and #shown>0 then
    local firstSource=math.max(1,(box.lineIndex or #page)-#shown+1)
    for i=1,#shown do
      fullLines[i]=page[firstSource+i-1] or ""
    end
  end

  local metricKey=table.concat(fullLines,"\n")
      .."|"..tostring(pageComplete)
      .."|text="..tostring(optionValue("uiTextSize"))
      .."|weight="..tostring(optionValue("uiTextWeight"))
      .."|box="..tostring(optionValue("uiBoxScale"))
      .."|w="..tostring(math.floor(w+0.5))
      .."|h="..tostring(math.floor(h+0.5))

  if not box.__gen3DialogueMetricCache
      or box.__gen3DialogueMetricCache.key~=metricKey then
    local size,glyphH,lineH,blockH,wrapped
    if #fullLines>0 then
      size,glyphH,lineH,blockH,wrapped=GoldCompat.fittedCompletedDialogue(
        fullLines,preferred,minimum,contentW,innerH)
    else
      size,glyphH,lineH,blockH=fittedDialogueMetrics(
        fullLines,preferred,minimum,contentW,innerH)
    end
    box.__gen3DialogueMetricCache={key=metricKey,size=size,glyphH=glyphH,
      lineH=lineH,blockH=blockH,wrapped=wrapped}
  end

  local metrics=box.__gen3DialogueMetricCache
  local pxSize,glyphH,lineH,blockH=
    metrics.size,metrics.glyphH,metrics.lineH,metrics.blockH

  local texts
  if pageComplete and metrics.wrapped then
    texts=metrics.wrapped
  else
    texts={}
    for i=1,visible do
      texts[i]=GoldCompat.dialogueVisibleText(box,i)
    end
  end
  visible=math.min(2,#texts)

  local firstY=y+innerTop+math.max(0,(innerH-blockH)*0.5)+off

  -- Same metric-driven layout as battle dialogue.
  g.setScissor(
    math.floor(x+5*sc),
    math.floor(y+innerTop-1),
    math.floor(w-10*sc),
    math.floor(innerH+2)
  )
  for i=1,visible do
    local ty=math.floor(firstY+(i-1)*lineH+0.5)
    printText(texts[i],textX,ty,pxSize,{0.04,0.04,0.04,1},
      "left",contentW)
  end
  g.setScissor()

  -- CONFIRMED against real render/TextBox.lua: box.blink counts up 0-479
  -- (self.blink=(self.blink+1)%480) and the native arrow blinks on a much
  -- shorter, repeating cadence (roughly blink%60<30). Checking `< 30`
  -- directly against the raw 0-479 counter only left the arrow visible for
  -- the first ~30 frames of every 8-second cycle instead of blinking
  -- regularly. Cosmetic only, but easy to get right now that the real field
  -- is confirmed.
  if (box.waiting or (box.done and not box.choice and not box.auto and not box.stay))
      and (box.blink or 0) % 60 < 30 then
    printText("▼",math.floor(x+w-12*sc),math.floor(y+h-10*sc),
      math.max(10,math.floor(4*sc+0.5)),{0.10,0.10,0.09,1})
  end

  g.pop()
end

local function safeFooterText(text,lx,ly,size,color,ox,oy,sc,maxWidth)
  local drawSize=size
  local width=maxWidth or (160-lx-8)

  -- Footer legends are strictly single-line controls. Fit the font to the
  -- available logical width first, then draw WITHOUT a wrap width. Passing
  -- width into finalText caused long prompts such as A: CATCH LOCATIONS to
  -- wrap a second line into the 8px footer and overprint themselves.
  while drawSize>1.45 and finalTextWidth(text,drawSize,sc)>width do
    drawSize=drawSize-0.10
  end
  finalText(text,lx,ly,drawSize,color,ox,oy,sc)
end

-- -------------------------------------------------------------------------
-- Native SummaryMenu presentation.
-- SummaryMenu remains the owning state: its update/page/close behavior is
-- untouched. We only replace its draw surface while the Pokémon UI is enabled.
-- -------------------------------------------------------------------------

function DexUI.drawPartySummary(game, state)
  if not (game and state and state.mon) then return end

  if state.__gen3uiMoveManager then
    return GoldCompat.drawGoldMoveManager(state)
  end

  local mon = state.mon
  local def = game.data and game.data.pokemon and game.data.pokemon[mon.species]
  if not def then return end

  local page = state.page or 1
  local ox,oy,sc = safeFullCanvas()
  local g = love.graphics

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  g.setColor(0.94,0.93,0.87,1)
  g.rectangle("fill",0,0,160,144)

  -- Header.
  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,4,152,17)
  g.setColor(0.99,0.985,0.955,1)
  g.rectangle("fill",5,5,150,15)

  -- Main cards.
  g.setColor(0.12,0.12,0.11,1)
  roundedRect("fill",4,25,65,103,3)
  roundedRect("fill",72,25,84,103,3)
  g.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",6,27,61,99,2)
  roundedRect("fill",74,27,80,99,2)

  setCurrentBorderColor(1)
  roundedRect("line",7,28,59,97,2)
  roundedRect("line",75,28,78,97,2)

  -- Footer.
  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,132,152,8)
  g.pop()

  finalText(page == 1 and "POKéMON STATS" or "POKéMON MOVES",
    9,8,4.8,{0.06,0.06,0.06,1},ox,oy,sc)

  local name = mon.nickname or def.name or "POKéMON"
  finalText(name,10,31,4.4,{0.07,0.07,0.07,1},ox,oy,sc,"left",52)
  finalText("Lv."..tostring(mon.level or "?"),10,39,3.2,
    {0.20,0.20,0.18,1},ox,oy,sc)

  -- Keep the same active sprite-source resolver used by Party/PC/Pokédex.
  g.push("all")
  g.origin()
  pcall(drawSelectedBattleSprite,game,mon,
    ox+13*sc,oy+48*sc,47*sc,39*sc,"summary")
  g.pop()

  finalText(("#%03d"):format(tonumber(def.dex) or 0),10,91,3.25,
    {0.36,0.36,0.33,1},ox,oy,sc)

  local TypeChart = require("src.battle.TypeChart")

  local function evolutionRows()
    local rows={}
    local methods=(game.data and game.data.evolution_methods) or Evolution.METHODS or {}
    for _,evo in ipairs(def.evolutions or {}) do
      local target=game.data and game.data.pokemon and game.data.pokemon[evo.species]
      local targetName=(target and target.name) or tostring(evo.species or "?")
      local method=methods[evo.method]
      local how

      if method and type(method.describe)=="function" then
        local ok,value=pcall(method.describe,evo,game.data)
        if ok and value and tostring(value)~="" then
          how=tostring(value)
        end
      end

      if not how then
        if evo.level then
          how="Level "..tostring(evo.level)
        elseif evo.item then
          local item=game.data and game.data.items and game.data.items[evo.item]
          how=(item and item.name) or tostring(evo.item)
        elseif tostring(evo.method or ""):upper()=="TRADE" then
          how="Trade"
        else
          how=tostring(evo.method or "Special")
        end
      end

      rows[#rows+1]={name=targetName,how=how}
    end
    return rows
  end

  local types={}
  for _,t in ipairs(def.types or {}) do
    types[#types+1]=TypeChart.displayName(t)
  end
  finalText(#types>0 and table.concat(types," / ") or "N/A",
    10,98,3.15,{0.12,0.12,0.11,1},ox,oy,sc,"left",52)

  local status = mon.status or "OK"
  finalText("STATUS",10,106,2.75,{0.40,0.40,0.37,1},ox,oy,sc)
  finalText(tostring(status),10,111,3.25,
    status=="OK" and {0.16,0.42,0.20,1} or {0.44,0.14,0.36,1},
    ox,oy,sc)

  if page == 1 then

    -- Compact identity block: information complementary to the main Party card.
    local entry=def.dexEntry or {}
    finalText("SPECIES",79,31,2.85,{0.40,0.40,0.37,1},ox,oy,sc)
    finalText(tostring(entry.kind or "N/A"):upper(),79,36,3.25,
      {0.08,0.08,0.08,1},ox,oy,sc,"left",35)

    -- Evolution summary sits opposite SPECIES in the upper-right corner.
    local evos=evolutionRows()
    finalText("EVOLUTION",116,31,2.85,{0.40,0.40,0.37,1},ox,oy,sc)
    if #evos==0 then
      finalText("NONE",116,36,3.0,{0.28,0.28,0.26,1},ox,oy,sc)
    else
      local row=evos[1]
      finalText(row.name,116,36,2.95,{0.08,0.08,0.08,1},ox,oy,sc,"left",34)
      finalText(row.how,116,41,2.55,{0.30,0.30,0.28,1},ox,oy,sc,"left",34)
      if #evos>1 then
        finalText((" +%d BRANCH"):format(#evos-1),116,46,2.0,
          {0.36,0.36,0.33,1},ox,oy,sc,"left",34)
      end
    end

    if DexUI.heightLabel and DexUI.weightLabel then
      finalText("HT",79,49,2.7,{0.40,0.40,0.37,1},ox,oy,sc)
      finalText(DexUI.heightLabel(def),91,49,3.05,
        {0.08,0.08,0.08,1},ox,oy,sc)
      finalText("WT",116,49,2.7,{0.40,0.40,0.37,1},ox,oy,sc)
      finalText(DexUI.weightLabel(def),128,49,3.05,
        {0.08,0.08,0.08,1},ox,oy,sc,"left",23)
    end

    -- Live stats: deliberately compact because the main Party screen already
    -- exposes the detailed stat block. Values are laid out explicitly instead
    -- with explicit placement so values remain readable.
    local stats=mon.stats or {}
    finalText("STATS",79,59,2.75,{0.40,0.40,0.37,1},ox,oy,sc)

    local statPairs={
      {"HP",stats.hp or 0, "ATK",stats.attack or 0},
      {"DEF",stats.defense or 0, "SPD",stats.speed or 0},
      {"SPC",stats.special or 0, nil,nil},
    }
    for i,row in ipairs(statPairs) do
      local yy=64+(i-1)*6
      finalText(row[1],79,yy,2.55,{0.30,0.30,0.28,1},ox,oy,sc)
      finalText(tostring(row[2]),93,yy,2.75,{0.08,0.08,0.08,1},ox,oy,sc)
      if row[3] then
        finalText(row[3],114,yy,2.55,{0.30,0.30,0.28,1},ox,oy,sc)
        finalText(tostring(row[4]),132,yy,2.75,{0.08,0.08,0.08,1},ox,oy,sc)
      end
    end

    -- Species level-up learnset. Gen1 species definitions expose level-1 moves
    -- separately from the ordered {level, move} learnset, so merge both while
    -- avoiding duplicate move IDs. Two columns use the available panel width
    -- without sacrificing readability.
    finalText("LEVEL-UP MOVES",79,83,2.8,{0.40,0.40,0.37,1},ox,oy,sc)

    local learned={}
    local seenMoves={}
    for _,moveId in ipairs(def.level1Moves or {}) do
      if moveId and not seenMoves[moveId] then
        learned[#learned+1]={level=1,move=moveId}
        seenMoves[moveId]=true
      end
    end
    for _,learn in ipairs(def.learnset or {}) do
      if learn and learn.move and not seenMoves[learn.move] then
        learned[#learned+1]={level=tonumber(learn.level) or 1,move=learn.move}
        seenMoves[learn.move]=true
      end
    end
    table.sort(learned,function(a,b)
      if a.level==b.level then return tostring(a.move)<tostring(b.move) end
      return a.level<b.level
    end)

    local rowsPerColumn=7
    local maxShown=rowsPerColumn*2
    for i=1,math.min(maxShown,#learned) do
      local item=learned[i]
      local col=(i-1)>=rowsPerColumn and 1 or 0
      local row=(i-1)%rowsPerColumn
      local xx=80+col*36
      local yy=89+row*5.35
      local md=game.data.moves and game.data.moves[item.move]
      local moveName=(md and md.name) or tostring(item.move)
      finalText(("L%02d"):format(item.level),xx,yy,2.35,
        {0.36,0.36,0.33,1},ox,oy,sc)
      finalText(moveName,xx+11,yy,2.35,
        {0.08,0.08,0.08,1},ox,oy,sc,"left",26)
    end

    if #learned>maxShown then
      finalText((" +%d MORE"):format(#learned-maxShown),115,124,2.1,
        {0.36,0.36,0.33,1},ox,oy,sc,"left",31)
    end

    finalText("SELECT: MOVE MANAGER",9,134,2.00,
      {0.96,0.95,0.90,1},ox,oy,sc,"left",90)
    finalText("A / B: MOVES",100,134,2.15,
      {0.74,0.74,0.70,1},ox,oy,sc,"right",56)
  else
    finalText("CURRENT MOVES",80,31,3.0,{0.40,0.40,0.37,1},ox,oy,sc)

    local moves=mon.moves or {}
    if #moves==0 then
      finalText("NO MOVES",79,43,3.4,{0.36,0.36,0.33,1},ox,oy,sc)
    else
      for i=1,math.min(4,#moves) do
        local mv=moves[i]
        local md=game.data.moves and game.data.moves[mv.id]
        local y=38+(i-1)*21.5

        g.push("all")
        g.translate(ox,oy)
        g.scale(sc,sc)
        g.setColor(0.12,0.12,0.11,1)
        roundedRect("fill",78,y,70,19,2)
        g.setColor(0.985,0.975,0.93,1)
        roundedRect("fill",79,y+1,68,17,2)
        g.pop()

        finalText(md and md.name or tostring(mv.id or "MOVE"),
          82,y+3,3.35,{0.07,0.07,0.07,1},ox,oy,sc,"left",40)

        local pp=tonumber(mv.pp) or 0
        local maxpp=tonumber(md and md.pp) or pp
        -- Right edge is logical x=145. finalText's width extends to the
        -- right from its x coordinate, so start the field at 122 rather than
        -- 145 to keep PP completely inside the 148-wide move card.
        finalText(("PP %d/%d"):format(pp,maxpp),
          121,y+3,3.1,{0.20,0.20,0.18,1},ox,oy,sc,"right",23)

        local typeName=md and md.type and TypeChart.displayName(md.type) or "—"
        finalText(typeName,82,y+10,2.55,{0.34,0.34,0.31,1},ox,oy,sc,"left",22)

        local power=md and tonumber(md.power)
        local accuracy=md and tonumber(md.accuracy)
        local powerText=(power and power>0) and ("PWR "..tostring(power)) or "STATUS"
        local accText=(accuracy and accuracy>0) and ("ACC "..tostring(accuracy)) or ""
        finalText(powerText,104,y+10,2.35,{0.34,0.34,0.31,1},
          ox,oy,sc,"left",21)
        finalText(accText,126,y+10,2.35,{0.34,0.34,0.31,1},
          ox,oy,sc,"left",18)
      end
    end

    local nextExp=0
    if mon.level and mon.level<100 and mon.exp then
      nextExp=math.max(0,Growth.expForLevel(def.growthRate,mon.level+1)-mon.exp)
    end

    -- Large summary EXP treatment: keep the bar clearly above the values and
    -- away from the cyan card border.
    local expRatio=0
    if mon.level and mon.level<100 and mon.exp then
      local curFloor=Growth.expForLevel(def.growthRate,mon.level)
      local nextFloor=Growth.expForLevel(def.growthRate,mon.level+1)
      local span=math.max(1,nextFloor-curFloor)
      expRatio=math.max(0,math.min(1,(mon.exp-curFloor)/span))
    elseif mon.level and mon.level>=100 then
      expRatio=1
    end

    g.push("all")
    g.origin()
    local ex=ox+11*sc
    local ey=oy+116.0*sc
    local ew=50*sc
    local eh=2.8*sc
    g.setColor(0.10,0.16,0.18,1)
    roundedRect("fill",ex,ey,ew,eh,eh*0.48)
    local inset=0.65*sc
    g.setColor(0.12,0.50,0.86,1)
    roundedRect("fill",ex+inset,ey+inset,
      math.max(0,(ew-inset*2)*expRatio),math.max(0,eh-inset*2),
      math.max(0.5*sc,(eh-inset*2)*0.45))
    g.pop()

    finalText("EXP",11,120.5,2.65,{0.34,0.45,0.50,1},ox,oy,sc)
    finalText(tostring(mon.exp or 0),25,120.5,2.85,{0.08,0.08,0.08,1},ox,oy,sc)
    finalText("NEXT",43,120.5,2.65,{0.40,0.40,0.37,1},ox,oy,sc)
    finalText(tostring(nextExp),59,120.5,2.85,{0.08,0.08,0.08,1},ox,oy,sc)

    finalText("SELECT: MOVE MANAGER",9,134,2.00,
      {0.96,0.95,0.90,1},ox,oy,sc,"left",90)
    finalText("A / B: BACK",100,134,2.15,
      {0.74,0.74,0.70,1},ox,oy,sc,"right",56)
  end
end


-- -------------------------------------------------------------------------
-- Pokédex presentation.
-- Namespaced deliberately: main.lua is close to Lua's 200-local chunk limit.
-- -------------------------------------------------------------------------

function DexUI.buildIndex(game)
  local out={}
  for species,def in pairs((game and game.data and game.data.pokemon) or {}) do
    local n=def and tonumber(def.dex)
    if n then
      out[n]={id=def.id or species,def=def}
    end
  end
  return out
end

function DexUI.locationName(game,mapId)
  local maps=game and game.data and game.data.maps
  local def=maps and maps[mapId]
  if type(def)=="table" then
    local name=def.name or def.label or def.displayName
    if name and tostring(name)~="" then return tostring(name) end
  end

  local field=game and game.data and game.data.field
  local townMap=field and field.townMap
  if type(townMap)=="table" then
    local locations=townMap.locations or townMap
    local e=type(locations)=="table" and locations[mapId]
    if type(e)=="table" then
      local name=e.name or e.label
      if name and tostring(name)~="" then return tostring(name) end
    end
  end

  return tostring(mapId or "N/A"):gsub("_"," ")
end


function DexUI.speciesLabel(def)
  local e=def and def.dexEntry
  local value=e and e.kind
  if value and tostring(value)~="" then
    return tostring(value):upper()
  end
  return "N/A"
end

function DexUI.heightLabel(def)
  local e=def and def.dexEntry
  if not e then return "N/A" end

  -- Match Gen1Recomp's native DexEntryMenu exactly.
  if e.heightM then
    return ("%.1f m"):format(e.heightM)
  end

  if e.heightFt then
    return ("%d' %02d\""):format(e.heightFt,e.heightIn or 0)
  end

  -- Gold stores the native four printed digits directly (e.g. 0108 = 1'08").
  if e.gen2Height~=nil then
    local raw=math.max(0,tonumber(e.gen2Height) or 0)
    local feet=math.floor(raw/100)
    local inches=raw%100
    return ("%d' %02d\""):format(feet,inches)
  end

  return "N/A"
end

function DexUI.weightLabel(def)
  local e=def and def.dexEntry
  if not e then return "N/A" end

  -- Match Gen1Recomp's native DexEntryMenu exactly.
  if e.heightM then
    return ("%.1f kg"):format(e.weightKg or 0)
  end

  if e.weight~=nil then
    return ("%.1f lb"):format((e.weight or 0)/10)
  end

  if e.gen2Weight~=nil then
    return ("%.1f lb"):format((tonumber(e.gen2Weight) or 0)/10)
  end

  return "N/A"
end

function DexUI.methodName(key,group)
  local raw=tostring(
    (type(group)=="table" and (group.method or group.type or group.name))
      or key or ""
  ):upper():gsub("_"," ")

  if raw:find("OLD",1,true) and raw:find("ROD",1,true) then return "OLD ROD" end
  if raw:find("GOOD",1,true) and raw:find("ROD",1,true) then return "GOOD ROD" end
  if raw:find("SUPER",1,true) and raw:find("ROD",1,true) then return "SUPER ROD" end
  if raw:find("SURF",1,true) or raw:find("WATER",1,true) then return "SURF" end
  if raw:find("GRASS",1,true) or raw:find("LAND",1,true)
      or raw:find("CAVE",1,true) or raw:find("WALK",1,true) then
    return "GRASS"
  end
  if raw:find("FISH",1,true) or raw:find("ROD",1,true) then return "FISHING" end
  return raw~="" and raw or "WILD"
end

function GoldCompat.dexEncounterRows(menu,speciesId)
  if not (menu and speciesId) then return {} end

  local data=menu.data or (menu.game and menu.game.data) or {}
  local save=menu.save or (menu.game and menu.game.save)
  local enc=data.gen2Encounters or data.encounters or {}
  local Nests=GoldCompat.engineModule("src.core.gen2.Nests")

  local out={}
  local seen={}

  local function cleanName(name)
    name=tostring(name or ""):gsub("\n"," "):gsub("\\n"," "):gsub("%s+"," ")
    return name:gsub("^%s+",""):gsub("%s+$","")
  end

  local function mapLabel(mapId)
    local map=(data.maps and data.maps[mapId])
      or (data.gen2Maps and data.gen2Maps[mapId])
    if not map then return cleanName(mapId) end

    -- Prefer the same landmark registry Gold's AREA/Pokégear code uses.
    if Nests and type(Nests.landmark)=="function" and map.landmark then
      local ok,mark=pcall(Nests.landmark,data,map.landmark)
      if ok and mark and mark.name then return cleanName(mark.name) end
    end
    return cleanName(map.label or map.name or mapId)
  end

  local function add(mapId,method)
    if not mapId then return end
    local area=mapLabel(mapId)
    if area=="" then return end
    local token=tostring(mapId).."|"..tostring(method or "WILD")
    if seen[token] then return end
    seen[token]=true
    out[#out+1]={area=area,method=method or "WILD",map=mapId}
  end

  local function slotListHas(list)
    if type(list)~="table" then return false end
    for _,slot in ipairs(list) do
      if type(slot)=="table" and slot.species==speciesId then return true end
    end
    return false
  end

  local function encounterRowHas(row)
    if type(row)~="table" then return false end
    local slots=row.slots
    if type(slots)~="table" then return false end

    -- Water is a flat slot list; grass is a MORN/DAY/NITE map of lists.
    if slotListHas(slots) then return true end
    for _,list in pairs(slots) do
      if slotListHas(list) then return true end
    end
    return false
  end

  -- Gold's merged Gen 2 encounter registry lives at gen2Encounters.
  -- Read all map-keyed grass/water sources directly rather than depending on
  -- the native Nests helper's legacy data.encounters path.
  for _,kind in ipairs({
    {"grass","GRASS"},
    {"swarmGrass","SWARM"},
    {"water","SURF"},
    {"swarmWater","SWARM"},
  }) do
    for mapId,row in pairs(enc[kind[1]] or {}) do
      if encounterRowHas(row) then add(mapId,kind[2]) end
    end
  end

  -- Headbutt / Rock Smash are map -> set indirections.
  local treeSets=enc.treeSets or {}
  local function setHas(setId)
    local set=treeSets[setId]
    if type(set)~="table" then return false end
    return slotListHas(set.common) or slotListHas(set.rare)
  end
  for mapId,setId in pairs(enc.trees or {}) do
    if setHas(setId) then add(mapId,"HEADBUTT") end
  end
  for mapId,setId in pairs(enc.rocks or {}) do
    if setHas(setId) then add(mapId,"ROCK SMASH") end
  end

  -- Bug Contest has one canonical location.
  for _,slot in ipairs(enc.bugContest or {}) do
    if type(slot)=="table" and slot.species==speciesId then
      local contestMap=(data.maps and data.maps.NATIONAL_PARK
        and "NATIONAL_PARK") or "NATIONAL_PARK"
      add(contestMap,"BUG CONTEST")
      break
    end
  end

  -- Fishing groups are indirect. Gold datasets can expose the group on the map
  -- under different extractor-era keys, so accept the known presentation keys.
  local matchingFish={}
  for groupId,group in pairs(enc.fishGroups or {}) do
    if type(group)=="table" then
      for _,rod in ipairs({"old","good","super"}) do
        if slotListHas(group[rod]) then matchingFish[groupId]=rod:upper() end
      end
    end
  end
  if next(matchingFish) then
    local maps=data.maps or data.gen2Maps or {}
    for mapId,map in pairs(maps) do
      if type(map)=="table" then
        local gid=map.fishGroup or map.fishingGroup or map.fish
          or map.fishGroupId or map.fishing
        if gid and matchingFish[gid] then
          add(mapId,matchingFish[gid].." ROD")
        end
      end
    end
  end

  -- Roamers: preserve Gold's current-map behavior.
  if okNests and Nests and type(Nests.find)=="function" then
    local ok,found=pcall(Nests.find,data,speciesId,nil,save)
    if ok and type(found)=="table" then
      for _,landmark in ipairs(found) do
        local mark=type(Nests.landmark)=="function" and Nests.landmark(data,landmark)
        local area=mark and cleanName(mark.name)
        if area and area~="" then
          local token="LANDMARK|"..tostring(landmark)
          if not seen[token] then
            seen[token]=true
            out[#out+1]={area=area,method="WILD",landmark=landmark}
          end
        end
      end
    end
  end

  table.sort(out,function(a,b)
    if a.area==b.area then return tostring(a.method)<tostring(b.method) end
    return tostring(a.area)<tostring(b.area)
  end)

  return out
end

function DexUI.encounters(game,speciesId)
  if game and game.__gen2PokedexMenu then
    return GoldCompat.dexEncounterRows(game.__gen2PokedexMenu,speciesId)
  end

  local out={}
  local seen={}
  local all=(game and game.data and game.data.encounters) or {}

  for mapId,enc in pairs(all) do
    if type(enc)=="table" then
      for key,group in pairs(enc) do
        if type(group)=="table" then
          local slots=group.slots or group
          local found=false

          if type(slots)=="table" then
            for _,slot in pairs(slots) do
              if type(slot)=="table"
                  and (slot.species==speciesId or slot.id==speciesId) then
                found=true
                break
              end
            end
          end

          if found then
            local area=DexUI.locationName(game,mapId)
            local method=DexUI.methodName(key,group)
            local token=area.."|"..method
            if not seen[token] then
              seen[token]=true
              out[#out+1]={area=area,method=method}
            end
          end
        end
      end
    end
  end

  table.sort(out,function(a,b)
    if a.area==b.area then return a.method<b.method end
    return a.area<b.area
  end)
  return out
end

function DexUI.ball(ox,oy,sc,lx,ly,caught)
  local g=love.graphics
  local cx=ox+lx*sc
  local cy=oy+ly*sc
  local r=2.3*sc

  g.push("all")
  g.origin()

  if caught then
    g.setColor(0.90,0.18,0.14,1)
    g.arc("fill","pie",cx,cy,r,math.pi,math.pi*2)
    g.setColor(0.98,0.98,0.94,1)
    g.arc("fill","pie",cx,cy,r,0,math.pi)
    g.setColor(0.08,0.08,0.07,1)
    g.setLineWidth(math.max(1,0.55*sc))
    g.circle("line",cx,cy,r)
    g.line(cx-r,cy,cx+r,cy)
    g.setColor(0.98,0.98,0.94,1)
    g.circle("fill",cx,cy,r*0.28)
  else
    g.setColor(0.38,0.39,0.37,0.42)
    g.setLineWidth(math.max(1,0.7*sc))
    g.circle("line",cx,cy,r)
    g.line(cx-r,cy,cx+r,cy)
  end

  g.pop()
end

function DexUI.draw(game,state)
  if not (game and state and state.items) then return end

  local ox,oy,sc=safeFullCanvas()
  local g=love.graphics
  local index=state.__gen3uiDexIndex
  if not index then
    index=DexUI.buildIndex(game)
    state.__gen3uiDexIndex=index
  end

  local total=#state.items
  local selected=math.max(1,math.min(state.index or 1,math.max(1,total)))
  local entry=index[selected]
  local speciesId=entry and entry.id
  local def=entry and entry.def
  local dex=(game.save and game.save.pokedex) or {seen={},owned={}}

  local seen=speciesId and (
    (dex.seen and dex.seen[speciesId]) or
    (dex.owned and dex.owned[speciesId])
  )
  local owned=speciesId and dex.owned and dex.owned[speciesId]

  local seenCount,ownedCount=0,0
  for _,e in pairs(index) do
    if dex.owned and dex.owned[e.id] then
      ownedCount=ownedCount+1
      seenCount=seenCount+1
    elseif dex.seen and dex.seen[e.id] then
      seenCount=seenCount+1
    end
  end

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  -- Gen 2 is a true hanging-overworld screen, matching the Party menu and the
  -- Colosseum UI ownership model. Do not paint the shared 160x144 donor
  -- backplate on Gold; Gen 1 keeps its established full-page Pokédex exactly
  -- as-is. The actual header/cards/footer below still own their own surfaces.
  if not game.__gen2PokedexMenu then
    g.setColor(0.94,0.93,0.87,1)
    g.rectangle("fill",0,0,160,144)
  end

  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,4,152,17)
  g.setColor(0.99,0.985,0.955,1)
  g.rectangle("fill",5,5,150,15)

  g.setColor(0.12,0.12,0.11,1)
  roundedRect("fill",4,25,88,104,3)
  roundedRect("fill",95,25,61,104,3)
  g.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",6,27,84,100,2)
  roundedRect("fill",97,27,57,100,2)

  setCurrentBorderColor(1)
  roundedRect("line",7,28,82,98,2)
  roundedRect("line",98,28,55,98,2)

  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,132,152,8)
  g.pop()

  finalText("POKéDEX",9,8,5.0,{0.06,0.06,0.06,1},ox,oy,sc)
  finalText(("SEEN %d  CAUGHT %d"):format(seenCount,ownedCount),
    79,8,3.15,{0.18,0.18,0.17,1},ox,oy,sc,"right",72)

  local shownName=(seen and def and def.name) or "-----"
  local selectedDex=(entry and tonumber(entry.dex))
      or (def and tonumber(def.dex)) or selected
  finalText(("#%03d  %s"):format(selectedDex,shownName),
    11,32,4.2,{0.07,0.07,0.07,1},ox,oy,sc,"left",74)

  finalText("STATUS",11,44,2.7,{0.38,0.38,0.35,1},ox,oy,sc)
  finalText(owned and "CAUGHT" or (seen and "SEEN" or "UNKNOWN"),
    11,49,3.4,
    owned and {0.16,0.42,0.20,1}
      or (seen and {0.46,0.35,0.10,1} or {0.42,0.42,0.40,1}),
    ox,oy,sc)

  if seen and def then
    finalText("SPECIES",11,58,2.5,{0.38,0.38,0.35,1},ox,oy,sc)
    finalText(DexUI.speciesLabel(def),11,63,3.0,{0.08,0.08,0.08,1},
      ox,oy,sc,"left",42)

    finalText("HT",11,70,2.5,{0.38,0.38,0.35,1},ox,oy,sc)
    finalText(DexUI.heightLabel(def),21,70,2.9,{0.08,0.08,0.08,1},
      ox,oy,sc,"left",24)

    finalText("WT",47,70,2.5,{0.38,0.38,0.35,1},ox,oy,sc)
    finalText(DexUI.weightLabel(def),57,70,2.9,{0.08,0.08,0.08,1},
      ox,oy,sc,"left",28)
  else
    finalText("SPECIES",11,58,2.5,{0.38,0.38,0.35,1},ox,oy,sc)
    finalText("N/A",11,63,3.0,{0.42,0.42,0.40,1},ox,oy,sc)
  end

  -- Match Party/PC compatibility: resolve the selected species through the
  -- live battle-sprite path so equipped sprite packs carry into the Pokédex.
  if seen and speciesId then
    g.push("all")
    g.origin()
    pcall(drawSelectedBattleSprite,game,{species=speciesId},
      ox+60*sc,oy+38*sc,24*sc,23*sc,"dex")
    g.pop()
  end

  finalText("WILD LOCATIONS",11,82,2.7,{0.38,0.38,0.35,1},ox,oy,sc)

  local rows=(seen and speciesId) and DexUI.encounters(game,speciesId) or {}

  -- Presentation-only cleanup. Keep the proven encounter lookup untouched.
  local displayRows={}
  local displaySeen={}
  local safariAdded=false

  for _,sourceRow in ipairs(rows) do
    local area=tostring(sourceRow.area or "N/A")
    local method=tostring(sourceRow.method or "WILD")

    -- Format only the displayed label:
    -- Route24 -> Route 24
    -- ViridianForest -> Viridian Forest
    area=area:gsub("_"," ")
    area=area:gsub("(%a)(%d)","%1 %2")
    area=area:gsub("(%d)(%a)","%1 %2")
    area=area:gsub("(%l)(%u)","%1 %2")
    area=area:gsub("%s+"," ")
    area=area:gsub("^%s+",""):gsub("%s+$","")

    local safariKey=area:lower()
    if safariKey:find("safari",1,true) then
      if not safariAdded then
        safariAdded=true
        displayRows[#displayRows+1]={area="Safari Zone",method=method}
      end
    else
      local token=area.."|"..method
      if not displaySeen[token] then
        displaySeen[token]=true
        displayRows[#displayRows+1]={area=area,method=method}
      end
    end
  end

  if #displayRows==0 then
    finalText("N/A",11,90,3.7,{0.12,0.12,0.11,1},ox,oy,sc)
  else
    for i=1,math.min(3,#displayRows) do
      local row=displayRows[i]
      local y=89+(i-1)*10
      finalText(row.area,11,y,2.9,{0.08,0.08,0.08,1},
        ox,oy,sc,"left",51)
      finalText(row.method,63,y,2.6,{0.34,0.26,0.08,1},
        ox,oy,sc,"left",23)
    end
    if #displayRows>3 then
      finalText((" +%d MORE"):format(#displayRows-3),11,119,2.6,
        {0.38,0.38,0.35,1},ox,oy,sc)
    end
  end

  local visibleRows=GoldCompat.dexListVisibleRows()
  local rowH=GoldCompat.dexListRowHeight()
  local first=math.max(1,selected-math.floor(visibleRows/2))
  if total>visibleRows then
    first=math.min(first,total-visibleRows+1)
  end

  for row=1,visibleRows do
    local n=first+row-1
    local item=state.items[n]
    if not item then break end

    local e=index[n]
    local id=e and e.id
    local isSeen=id and (
      (dex.seen and dex.seen[id]) or
      (dex.owned and dex.owned[id])
    )
    local caught=id and dex.owned and dex.owned[id]
    local name=(isSeen and e and e.def and e.def.name) or "-----"
    local y=31+(row-1)*rowH

    if n==selected then
      g.push("all")
      g.translate(ox,oy)
      g.scale(sc,sc)
      g.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",99,y-2,53,rowH-1,2)
      g.pop()
    end

    DexUI.ball(ox,oy,sc,103,y+2,caught)
    local rowDex=(e and tonumber(e.dex))
        or (e and e.def and tonumber(e.def.dex)) or n
    finalText(("%03d"):format(rowDex),107,y,2.6,
      n==selected and {0.98,0.97,0.92,1} or {0.34,0.34,0.32,1},
      ox,oy,sc)
    finalText(name,120,y,2.8,
      n==selected and {0.98,0.97,0.92,1} or {0.08,0.08,0.08,1},
      ox,oy,sc,"left",30)
  end

  safeFooterText("A: OPTIONS   B: BACK   ←/→: PAGE",9,134,2.5,
    {0.96,0.95,0.90,1},ox,oy,sc,142)
end


function DexUI.drawEntry(game,state)
  if not (game and state and state.def) then return end

  local ox,oy,sc=safeFullCanvas()
  local g=love.graphics
  local def=state.def
  local e=def.dexEntry or {}
  local dex=(game.save and game.save.pokedex) or {owned={}}
  local owned=state.forceOwned or (dex.owned and dex.owned[def.id])

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  -- Gold/Crystal/Silver use this as a hanging dossier over the live map.
  -- Preserve Gen 1's established opaque Pokédex page, but do not lay a full
  -- 160x144 sheet underneath the Gen 2 cards.
  if not game.__gen2PokedexMenu then
    g.setColor(0.94,0.93,0.87,1)
    g.rectangle("fill",0,0,160,144)
  end

  -- Header
  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,4,152,17)
  g.setColor(0.99,0.985,0.955,1)
  g.rectangle("fill",5,5,150,15)

  -- Main card
  g.setColor(0.12,0.12,0.11,1)
  roundedRect("fill",4,25,152,104,3)
  g.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",6,27,148,100,2)
  setCurrentBorderColor(1)
  roundedRect("line",7,28,146,98,2)

  -- Footer
  g.setColor(0.08,0.08,0.08,1)
  g.rectangle("fill",4,132,152,8)
  g.pop()

  finalText("POKéDEX DATA",9,8,4.8,{0.06,0.06,0.06,1},ox,oy,sc)

  -- Sprite panel on left.
  if def.id then
    g.push("all")
    g.origin()
    pcall(drawSelectedBattleSprite,game,{species=def.id},
      ox+12*sc,oy+34*sc,43*sc,42*sc,"dex")
    g.pop()
  end

  finalText(tostring(def.name or "-----"),61,32,4.5,
    {0.07,0.07,0.07,1},ox,oy,sc,"left",86)

  finalText(tostring(e.kind or "N/A"):upper(),61,42,3.8,
    {0.34,0.34,0.31,1},ox,oy,sc,"left",86)

  finalText(("No. %03d"):format(tonumber(def.dex) or 0),61,51,3.8,
    {0.08,0.08,0.08,1},ox,oy,sc)

  if owned then
    finalText("HT",61,61,3.25,{0.38,0.38,0.35,1},ox,oy,sc)
    finalText(DexUI.heightLabel(def),73,61,3.55,
      {0.08,0.08,0.08,1},ox,oy,sc,"left",29)

    finalText("WT",104,61,3.25,{0.38,0.38,0.35,1},ox,oy,sc)
    finalText(DexUI.weightLabel(def),116,61,3.55,
      {0.08,0.08,0.08,1},ox,oy,sc,"left",32)
  else
    finalText("DATA UNKNOWN",61,61,3.0,
      {0.42,0.42,0.40,1},ox,oy,sc)
  end

  -- Native DexEntry description source, presented in our card.
  local description=nil
  if owned and e.text and game.data and game.data.text then
    description=game.data.text[e.text]
  end

  finalText("ENTRY",12,77,3.45,{0.38,0.38,0.35,1},ox,oy,sc)

  if description and tostring(description)~="" then
    local clean=GoldCompat.cleanWrappedText(description)

    -- Wrap in logical Pokédex pixels, not final screen pixels. Multiplying
    -- this width by sc made the renderer believe an entire paragraph fit on
    -- one line at high window scales.
    local entrySize=4.35
    local entryWidth=132
    local f=font(entrySize*UI_TEXT_SCALE)
    local _,wrapped=f:getWrap(clean,entryWidth)
    local maxLines=4

    for i=1,math.min(maxLines,#wrapped) do
      finalText(wrapped[i],12,87+(i-1)*10,entrySize,
        {0.08,0.08,0.08,1},ox,oy,sc,"left",entryWidth)
    end
  else
    finalText("Data unknown.",12,88,3.2,
      {0.30,0.30,0.28,1},ox,oy,sc)
  end

  safeFooterText("A / B: BACK",9,134,2.6,
    {0.96,0.95,0.90,1},ox,oy,sc,142)
end


function DexUI.drawAction(game,state)
  if not state then return end

  -- Keep the full new Pokédex visible beneath the native option state.
  if DexUI.active then
    DexUI.draw(game,DexUI.active)
  end

  local ox,oy,sc=safeFullCanvas()
  local g=love.graphics
  local items=state.items or {}
  local count=math.max(1,#items)

  -- Compact action card so normal middle-list selections can genuinely open
  -- beneath the selected row instead of immediately flipping above it.
  local w=34
  -- Row label draws at 2.75 below -- dynamic to match TEXT SIZE (General
  -- Sweep, v2.1.28). This card already sizes itself (`h`) from rowH*count,
  -- so growing rowH here needs no separate shrink-to-fit step.
  local rowH=GoldCompat.dynamicRowHeight(2.75,9,3)
  local h=6+count*rowH
  local x=119

  local y=31
  if DexUI.active and DexUI.active.items then
    local total=#DexUI.active.items
    local selected=math.max(1,math.min(DexUI.active.index or 1,math.max(1,total)))
    -- Must match DexUI.draw's own row count/height exactly (dexListVisibleRows/
    -- dexListRowHeight), or this flyout drifts away from the row it should
    -- sit beside once TEXT SIZE changes the main list's own row count.
    local visibleRows=GoldCompat.dexListVisibleRows()
    local listRowH=GoldCompat.dexListRowHeight()
    local first=math.max(1,selected-math.floor(visibleRows/2))
    if total>visibleRows then
      first=math.min(first,total-visibleRows+1)
    end

    local visibleRow=selected-first+1
    local selectedY=31+(visibleRow-1)*listRowH
    local belowY=selectedY+listRowH-1

    -- Prefer below. Flip only for genuinely bottom-most rows where even the
    -- compact card cannot fit inside the panel.
    if belowY+h<=127 then
      y=belowY
    else
      y=selectedY-h-2
    end
  end

  if y<29 then y=29 end
  if y+h>128 then y=128-h end

  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  g.setColor(0.10,0.10,0.09,1)
  roundedRect("fill",x,y,w,h,3)
  g.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+2,y+2,w-4,h-4,2)
  setCurrentBorderColor(1)
  roundedRect("line",x+3,y+3,w-6,h-6,2)

  for i,item in ipairs(items) do
    local yy=y+4+(i-1)*rowH
    local selected=i==(state.index or 1)

    if selected then
      g.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",x+3,yy-1,w-6,rowH-1,2)
    end

    g.pop()
    finalText(tostring(item.label or ""),x+6,yy,2.75,
      selected and {0.98,0.97,0.92,1} or {0.07,0.07,0.07,1},
      ox,oy,sc,"left",w-11)
    g.push("all")
    g.translate(ox,oy)
    g.scale(sc,sc)
  end

  g.pop()
end


function DexUI.hud(next,game,viewport)
  -- Dedicated wrapper keeps Pokédex references out of the already-large
  -- renderHudHook, avoiding LuaJIT's 60-upvalue function limit.
  next(game,viewport)

  local state=DexUI.active
  if not state then
    DexUI.action=nil
    return
  end

  if not featureEnabled("revampedPokedex") then
    DexUI.active=nil
    DexUI.action=nil
    DexUI.entry=nil
    return
  end

  if not stateExistsInStack(game,state) then
    DexUI.active=nil
    DexUI.action=nil
    DexUI.entry=nil
    return
  end

  local top=topState(game)

  if DexUI.entry
      and stateExistsInStack(game,DexUI.entry)
      and top==DexUI.entry then
    local ok,err=pcall(DexUI.drawEntry,game,DexUI.entry)
    if not ok then
      DexUI.entry.__gen3uiDexEntryRenderFailed=true
      if modRef and modRef.log then
        modRef.log:error("Gen 3 UI Pokédex DATA renderer failed: "
          ..tostring(err))
      end
    end
    return
  elseif DexUI.entry and not stateExistsInStack(game,DexUI.entry) then
    DexUI.entry=nil
  end

  if DexUI.action
      and stateExistsInStack(game,DexUI.action)
      and top==DexUI.action then
    local ok,err=pcall(DexUI.drawAction,game,DexUI.action)
    if not ok then
      DexUI.action.__gen3uiPokedexActionRenderFailed=true
      if modRef and modRef.log then
        modRef.log:error("Gen 3 UI Pokédex action overlay failed: "
          ..tostring(err))
      end
    end
    return
  elseif DexUI.action and not stateExistsInStack(game,DexUI.action) then
    DexUI.action=nil
  end

  if top~=state then return end

  local ok,err=pcall(DexUI.draw,game,state)
  if not ok then
    state.__gen3uiPokedexRenderFailed=true
    DexUI.active=nil
    if modRef and modRef.log then
      modRef.log:error("Gen 3 UI Pokédex renderer failed; native fallback: "
        ..tostring(err))
    end
  end
end


function GoldCompat.drawChoiceThemeFinal(box)
  local g = love.graphics
  local sw,sh = g.getDimensions()
  local sc = math.max(1,sh/144)

  local margin = math.floor(4*sc+0.5)
  local dialogueH = math.floor(24*sc+0.5)
  local w = math.floor(48*sc+0.5)
  local h = math.floor(34*sc+0.5)
  local x = sw-w-margin
  local y = sh-dialogueH-margin-h-math.floor(3*sc+0.5)

  g.push("all")
  g.origin()
  g.setColor(0.08,0.08,0.07,1)
  g.rectangle("fill",x,y,w,h)
  g.setColor(0.99,0.985,0.95,1)
  g.rectangle("fill",x+2*sc,y+2*sc,w-4*sc,h-4*sc)
  drawUnifiedBorder(x,y,w,h,0)

  local row1 = math.floor(y+5*sc+0.5)
  local row2 = math.floor(y+18*sc+0.5)
  local selected = box.index or 1
  g.setColor(0.10,0.10,0.09,1)
  g.rectangle("fill",x+5*sc,(selected==1 and row1 or row2)-sc,w-10*sc,11*sc)

  local pxSize = math.max(12,math.floor(5*sc+0.5))
  printText(Strings("YES"),math.floor(x+10*sc),row1,pxSize,
    selected==1 and {1,1,1,1} or {0.04,0.04,0.04,1})
  printText(Strings("NO"),math.floor(x+10*sc),row2,pxSize,
    selected==2 and {1,1,1,1} or {0.04,0.04,0.04,1})
  g.pop()
end
local function installDialogueThemeDirect(mod)
  local originalTextBoxDraw = TextBox.draw
  TextBox.draw = function(self)
    local strictBattle=GoldCompat.strictBattleUiForGame(self.game)
    if not featureEnabled("revampedDialogueBoxes") and not strictBattle then
      State.activeDialogueBox = nil
      return originalTextBoxDraw(self)
    end

    -- Revamped mode is exclusive: suppress the vanilla box completely.
    -- Mark this TextBox for final-HUD rendering in the current frame.
    State.activeDialogueBox = self

    -- Preserve the only draw-time state mutation from vanilla TextBox.draw:
    -- the 8px scroll animation decays by 2px per rendered frame.
    if self.scrollPx and self.scrollPx > 0 then
      self.scrollPx = self.scrollPx - 2
      if self.scrollPx <= 0 then self.scrollPx = nil end
    end

    local r = self.game and self.game.renderer
    if r and r.setUIAnchor then
      r:setUIAnchor(self.boxTx * 8, self.boxTy * 8,
                    self.boxTw * 8, self.boxTh * 8, "bottom")
    end
  end

  local originalChoiceDraw = ChoiceBox.draw
  ChoiceBox.draw = function(self)
    -- Starter confirmation is a dedicated full-screen surface even when the
    -- general dialogue theme is disabled. Identify it at the actual state draw
    -- boundary so the native/generic choice can never leak into the same frame.
    local parity=GoldCompat.FeatureParity
    if parity and type(parity.claimStarter)=="function" then
      pcall(parity.claimStarter,self.game,self)
    end
    if self.__gen3uiStarterSpecies and featureEnabled("revampedStarterUI") then
      State.activeChoiceBox=self
      return
    end
    local strictBattle=GoldCompat.strictBattleUiForGame(self.game)
    if not featureEnabled("revampedDialogueBoxes") and not strictBattle then
      State.activeChoiceBox = nil
      return originalChoiceDraw(self)
    end

    -- Same exclusive behavior for YES / NO and other ChoiceBox prompts.
    State.activeChoiceBox = self
  end

  if mod.log then
    mod.log:info("Gen 3 Inspired UI Overhaul: final-HUD dialogue overlay installed")
  end
end


-- Entry
-- -------------------------------------------------------------------------


local function installPCIntegration()
  -- Bill's PC uses generic Menu/ListMenu classes internally. Mark only the
  -- exact PC-owned instances so our renderer stays compatible with unrelated
  -- menus and other mods.
  local originalBoxMenuNew=BoxMenu.new
  BoxMenu.new=function(game,...)
    local menu=originalBoxMenuNew(game,...)
    if menu then
      menu.__gen3uiPCMain=true

      -- BoxMenu installs a per-instance draw() that appends the native
      -- "What?" / "BOX No." chrome after Menu.draw. Replace only THIS
      -- BoxMenu instance's presentation hook; update/input remain native.
      local nativeBoxDraw=menu.draw
      menu.draw=function(self)
        if not featureEnabled("revampedPokemonPC") then
          return nativeBoxDraw(self)
        end
        State.activePCMenu=self
      end
    end
    return menu
  end

  -- Gen 1's real src/ui/ShopMenu.lua (pokemart.asm DisplayPokemartDialogue_)
  -- builds its BUY/SELL/QUIT menu via the shared Menu.new (already correctly
  -- flagged __gen3uiShopMain below via shopMainItems' label match), then
  -- immediately does `menu.draw = function(self) drawClerk(self); Menu.draw(
  -- self) end` on that SAME instance -- an instance field always wins over
  -- the Menu.draw class patch below, the same shadowing bug already found
  -- for the Pokédex side menu (v2.1.20) and fixed the same way here: capture
  -- native's own instance override, then replace it one more time so ours
  -- is the one Lua actually finds each frame. drawClerk drew the vanilla
  -- money box and greeting/footer text directly onto the canvas (not
  -- through a TextBox this mod's dialogue theme could already catch) --
  -- that vanilla leak is exactly what the screenshot showed alongside an
  -- otherwise-already-working BUY/SELL/EXIT box. drawShopMainFinal now
  -- draws both itself (GoldCompat.drawShopFrame's money bar + state.footer).
  local originalShopMenuNew=ShopMenu.new
  ShopMenu.new=function(...)
    local menu=originalShopMenuNew(...)
    if menu then
      local nativeShopDraw=menu.draw
      menu.draw=function(self)
        if not featureEnabled("revampedPokeMartUI")
            or self.__gen3uiMartRenderFailed then
          return nativeShopDraw(self)
        end
        State.activeShopMenu=self
      end
    end
    return menu
  end

  local originalMenuNew=Menu.new
  Menu.new=function(game,items,opts,...)
    local menu=originalMenuNew(game,items,opts,...)
    if menu then
      local first=shopMenuLabel(items and items[1])
      local second=shopMenuLabel(items and items[2])

      -- Every out-of-battle Bag item goes through this shared USE/TOSS menu
      -- before TM/HM or evolution-stone targeting. Mark it immediately and
      -- prevent its native opaque screen from clearing the frame white.
      if type(items)=="table" and #items==2
          and first=="USE" and second=="TOSS" then
        menu.__gen3uiBagAction=true
        menu.isOpaque=false
      elseif type(items)=="table" and DexUI.active then
        local dexHits=0
        for _,entry in ipairs(items) do
          local label=shopMenuLabel(entry)
          if label=="DATA" or label=="CRY" or label=="AREA"
              or label=="QUIT" or label=="CANCEL" then
            dexHits=dexHits+1
          end
        end
        if dexHits>=2 then
          menu.__gen3uiPokedexAction=true
          menu.isOpaque=false
          DexUI.action=menu
        elseif shopMainItems(items) then
          menu.__gen3uiShopMain=true
          menu.isOpaque=false
        elseif pcAccessItems(items) then
          menu.__gen3uiPCAccess=true
        elseif pcMainItems(items) then
          menu.__gen3uiPCMain=true
        elseif pcActionItems(items) then
          menu.__gen3uiPCAction=true
        end
      elseif shopMainItems(items) then
        menu.__gen3uiShopMain=true
        menu.isOpaque=false
      elseif pcAccessItems(items) then
        menu.__gen3uiPCAccess=true
      elseif pcMainItems(items) then
        menu.__gen3uiPCMain=true
      elseif pcActionItems(items) then
        menu.__gen3uiPCAction=true
      end
    end
    return menu
  end

  local originalListMenuNew=ListMenu.new
  ListMenu.new=function(game,title,items,opts,...)
    local list=originalListMenuNew(game,title,items,opts,...)
    local upperTitle=tostring(title or ""):upper()

    -- Gen 1's real src/ui/BoxMenu.lua (bills_pc.asm) pushes these three
    -- Pokémon-list screens with title=nil, conveying identity only through
    -- opts.kind ("pc_box_withdraw"/"pc_box_deposit"/"pc_box_release", which
    -- ListMenu.new stores as self.kind = opts.kind or title -- see real
    -- src/ui/ListMenu.lua). GoldCompat.pcListTitle only ever matched title
    -- STRINGS (Gen 2's Gold PC apparently does pass one), so these three
    -- Gen 1 screens fell through to fully vanilla every time -- confirmed by
    -- screenshot. Check the exact Gen 1 kind values directly, ahead of the
    -- title-string fallback used for Gen 2.
    local kind=opts and opts.kind

    if list and (upperTitle=="POKéDEX" or upperTitle=="POKEDEX") then
      list.__gen3uiPokedex=true
      DexUI.active=list
    elseif list and opts and opts.dialogue and opts.itemBox
        and type(items)=="table" then
      -- Gen 1's real src/ui/ShopMenu.lua (pokemart.asm
      -- DisplayPokemartDialogue_) is the ONLY place in the whole engine that
      -- ever sets opts.dialogue (confirmed by grepping the real source) --
      -- so the upperTitle=="BUY"/"SELL" check this branch used to have was
      -- clearly meant for this exact screen, but both buy() and sell() push
      -- their list with title=nil, so it never matched either one; both fell
      -- straight through to fully vanilla (confirmed by screenshot). There's
      -- no title text to fall back on, so tell BUY from SELL structurally
      -- instead: every real BUY row carries a def.price ¥-string (buy()'s
      -- item constructor always sets it); SELL rows never do (sellItems()'s
      -- constructor only ever sets `.count`).
      local hasPrice=false
      for _,it in ipairs(items) do
        if it and it.price then hasPrice=true break end
      end
      list.__gen3uiShopList=true
      list.__gen3uiShopSell=not hasPrice

      -- Gen 1 SELL: reuse the Bag's own working pocket-category system
      -- (GEN1_BAG_POCKETS/gen1BagPocketFor) -- confirmed by the user that
      -- this already exists and works, and only the Mart's own item menu
      -- lacked it ("our bag ui already has built in categories in gen 1.
      -- The only item menu that doesn't have this is the pokemart ui").
      -- Unlike BagMenu, this is a plain ListMenu whose onChoose/onSelectKey/
      -- removeCurrent are real game logic (src/ui/ShopMenu.lua's sell())
      -- operating on list.items[list.index] directly, so every native
      -- action below points list.index at the exact entry the categorized
      -- view is showing before ever delegating to it.
      if list.__gen3uiShopSell and GoldCompat.generation=="gen1" then
        list.__gen3uiShopSellPocketIndex=1
        list.__gen3uiShopSellViewIndex=1
        list.__gen3uiShopSellViewScroll=0

        local nativeSellUpdate=list.update

        list.update=function(self,dt)
          if not featureEnabled("revampedPokeMartUI") then
            return nativeSellUpdate(self,dt)
          end
          if self.script then return nativeSellUpdate(self,dt) end

          local input=self.game and self.game.input
          local before=gen1ShopSellViewSelected(self)
          gen1ShopSellRefresh(self,before and not before.cancel
            and before.value or nil)

          if not input then return end

          -- ---------------------------------------------------------
          -- Horizontal pocket navigation. Native SELL never reads
          -- left/right itself (this ListMenu is pushed without
          -- opts.pageJump, so MenuRepeat.direction only ever resolves
          -- up/down for it -- confirmed against the real
          -- src/ui/ListMenu.lua), so there is no competing native
          -- behavior being overridden here.
          -- ---------------------------------------------------------
          local leftEdge=input:wasPressed("left")
          local rightEdge=input:wasPressed("right")
          local leftDown=input:isDown("left")
          local rightDown=input:isDown("right")

          if not leftDown and not rightDown then
            self.__gen3uiShopSellPocketHeld=nil
          end

          local pocketDir=nil
          if leftEdge or (leftDown and self.__gen3uiShopSellPocketHeld~="left") then
            pocketDir="left"
          elseif rightEdge
              or (rightDown and self.__gen3uiShopSellPocketHeld~="right") then
            pocketDir="right"
          end

          if pocketDir then
            self.__gen3uiShopSellPocketHeld=pocketDir
            local n=#GEN1_BAG_POCKETS
            if pocketDir=="left" then
              self.__gen3uiShopSellPocketIndex=
                ((self.__gen3uiShopSellPocketIndex or 1)-2)%n+1
            else
              self.__gen3uiShopSellPocketIndex=
                (self.__gen3uiShopSellPocketIndex or 1)%n+1
            end
            self.__gen3uiShopSellViewIndex=1
            self.__gen3uiShopSellViewScroll=0
            self.swapIndex=nil
            gen1ShopSellRefresh(self,nil)
            gen1ShopSellBeep(self)
            return
          end

          -- ---------------------------------------------------------
          -- Vertical navigation over the categorized view.
          -- ---------------------------------------------------------
          local moved=false
          if input:wasPressed("up") then
            moved=gen1ShopSellMoveView(self,-1)
          elseif input:wasPressed("down") then
            moved=gen1ShopSellMoveView(self,1)
          end
          if moved then
            gen1ShopSellBeep(self)
            return
          end

          -- ---------------------------------------------------------
          -- Native actions. Point list.index at the categorized view's
          -- selected native entry immediately before delegating, so
          -- onChoose/onSelectKey/removeCurrent (real game logic keyed
          -- off list.items[list.index]) act on the item the player
          -- actually sees selected.
          -- ---------------------------------------------------------
          if self.onSelectKey and input:wasPressed("select") then
            local row=gen1ShopSellViewSelected(self)
            -- Never forward SELECT while CANCEL is the visible selection:
            -- self.index is otherwise stale (nothing above keeps it synced
            -- to the categorized cursor except right before an action), and
            -- the real onSelectKey would swap whatever stale native index
            -- that happens to be against the player's actual reorder target
            -- instead of safely no-op'ing the way native does on a real
            -- CANCEL row.
            if not row or row.cancel then return end
            local nativeIndex=gen1BagNativeIndexForId(self,row.value)
            if nativeIndex then self.index=nativeIndex end
            nativeSellUpdate(self,dt)
            gen1ShopSellRefresh(self,row.value)
            return
          elseif input:wasPressed("b") then
            return nativeSellUpdate(self,dt)
          elseif input:wasPressed("a") then
            local row=gen1ShopSellViewSelected(self)
            if not row then return end
            gen1ShopSellBeep(self)
            if row.cancel then
              if self.onChoose then self.onChoose(row,self) end
              return
            end
            local nativeIndex=gen1BagNativeIndexForId(self,row.value)
            if nativeIndex then self.index=nativeIndex end
            if self.onChoose then self.onChoose(row,self) end
            return
          end
        end

        gen1ShopSellRefresh(list,nil)
      end
    elseif list and (kind=="pc_box_withdraw" or kind=="pc_box_deposit"
        or kind=="pc_box_release") then
      list.__gen3uiPCList=true
    elseif list and GoldCompat.pcListTitle(title) then
      list.__gen3uiPCList=true
    elseif list and kind=="elevator_floors" then
      -- Confirmed via the real data/scripts/story3.lua `elevator()` builder
      -- (shared by every Gen 1 elevator: Celadon Mart, Silph Co, Rocket
      -- Hideout): it pushes this exact ListMenu with title=nil and
      -- opts.kind="elevator_floors" -- a purpose-built, unique kind string,
      -- so no structural guessing is needed the way the Mart's BUY/SELL
      -- split needed. This list previously matched none of this mod's
      -- existing detection at all (Bag/Shop/PC/Pokédex only), so it fell
      -- straight through to fully vanilla, confirmed by screenshot -- it
      -- was never a case of gen3ui failing to intercept a screen it meant
      -- to cover, just a screen no branch here knew about yet.
      list.__gen3uiElevator=true
    end
    return list
  end
end


local function installGen1SaveScreen()
  -- Gen 1's real SAVE flow (src/ui/StartMenu.lua, inside the START menu's
  -- SAVE item's onSelect) pushes a bare table straight onto the stack, not
  -- an instance of any shared class this mod can patch the way
  -- OptionsMenu/BoxMenu/PokedexMenu/ShopMenu are patched elsewhere. Its own
  -- .draw prints the PLAYER/BADGES/POKéDEX/TIME panel directly with
  -- Font.drawBox/Font.draw (confirmed by reading the real source) -- and the
  -- later "Would you like to SAVE the game?" confirmation is a completely
  -- separate TextBox/ChoiceBox pushed on top of it a few frames later, so
  -- there is no single state to intercept for the whole flow anyway. This
  -- panel is also the ONLY thing in the entire engine that sets both
  -- `holdsUIAnchors` and `openPrompt` together (grepped the real source to
  -- confirm), so hook the one thing every pushed state -- including this
  -- one -- always goes through: StateStack:push itself. Re-tag this exact
  -- shape the instant it appears, using the same instance-field
  -- re-interception trick already proven for the Pokédex side menu, Bill's
  -- PC, and the Mart's own clerk box above (an instance field always wins
  -- over a class-level method in Lua, so there's nothing else to patch).
  local ok,StateStack=pcall(require,"src.core.StateStack")
  if not ok or type(StateStack)~="table" or StateStack.__gen3uiSaveWrapped then
    return
  end
  StateStack.__gen3uiSaveWrapped=true
  local originalStackPush=StateStack.push
  StateStack.push=function(self,state,...)
    if type(state)=="table" and state.holdsUIAnchors
        and type(state.openPrompt)=="function"
        and not state.__gen3uiSaveTagged then
      state.__gen3uiSaveTagged=true
      state.__gen3uiSavePanel=true
      local nativeSaveDraw=state.draw
      if type(nativeSaveDraw)=="function" then
        state.draw=function(self2)
          if not featureEnabled("revampedSaveUI")
              or self2.__gen3uiSaveRenderFailed then
            return nativeSaveDraw(self2)
          end
        end
      end
    end
    return originalStackPush(self,state,...)
  end
end


local function handleModOptionChanged(mod,payload)
  if not payload or payload.mod ~= mod.id then return end

  if payload.key~=nil and payload.value~=nil then
    GoldCompat.cacheOptionValue(payload.key,payload.value)
  else
    GoldCompat.invalidateOptionCache(payload.key)
  end

  if payload.key == "revampedBattleUI" and payload.value == false then
    clearBattleUIState()
  elseif payload.key == "revampedPokemonMenu" and payload.value == false then
    clearPokemonUIState()
    DexUI.summary=nil
  elseif payload.key == "revampedOverworldMenus" and payload.value == false then
    clearOverworldMenuState()
  elseif payload.key == "revampedPokeMartUI" and payload.value == false then
    clearShopUIState()
  elseif payload.key == "revampedPokemonPC" and payload.value == false then
    clearPCUIState()
  elseif payload.key == "revampedPokedex" and payload.value == false then
    DexUI.active=nil
    DexUI.action=nil
    DexUI.entry=nil
  elseif payload.key == "revampedDialogueBoxes" and payload.value == false then
    State.activeDialogueBox=nil
    State.activeChoiceBox=nil
  end
end


local goldBattleScrubInstalled=false

-- -------------------------------------------------------------------------
-- Pokémon Gold: Gen 3-inspired Pokégear presentation
-- -------------------------------------------------------------------------

function GoldCompat.drawPokegearWidescreen(self,winW,winH)
  local Pokegear=GoldCompat.requiredEngineModule("src.ui.gen2.Pokegear")
  local G=love.graphics

  -- Fly Map is a separate screen/state in Gen 2, not the Pokégear card UI.
  -- Preserve it verbatim until we theme the dedicated Gold map/fly surface.
  if self.fly and Pokegear.__gen3uiOriginalDrawWidescreen then
    return Pokegear.__gen3uiOriginalDrawWidescreen(self,winW,winH)
  end

  -- MAP is also temporarily fully native. The vanilla renderer is tightly
  -- coupled to mapCursor/mapLandmark/playerLandmark sprite placement and the
  -- moving landmark name plate. Our cropped card viewport hid enough of that
  -- state that the map appeared non-functional. Clock/Phone/Radio keep the
  -- Gen 3 shell; selecting MAP uses Gold's exact working map presentation.
  local activeCard=self.card and self:card()
    or (self.cards and self.cards[self.cardIndex or 1])
  if activeCard and activeCard.id=="map"
      and Pokegear.__gen3uiOriginalDrawWidescreen then
    return Pokegear.__gen3uiOriginalDrawWidescreen(self,winW,winH)
  end

  winW=winW or G.getWidth()
  winH=winH or G.getHeight()

  -- Cache a native-resolution card surface per live Pokégear instance.
  if not self.__gen3uiGearCanvas then
    local ok,canvas=pcall(G.newCanvas,160,144)
    if ok then
      self.__gen3uiGearCanvas=canvas
      if canvas.setFilter then pcall(canvas.setFilter,canvas,"nearest","nearest") end
    end
  end

  local canvas=self.__gen3uiGearCanvas
  if not canvas then
    if Pokegear.__gen3uiOriginalDrawWidescreen then
      return Pokegear.__gen3uiOriginalDrawWidescreen(self,winW,winH)
    end
    return
  end

  -- Draw the engine-owned live card first. We crop away its native 16px card
  -- strip and replace only that chrome with our high-resolution navigation.
  local oldCanvas=G.getCanvas()
  G.push("all")
  G.setCanvas(canvas)
  G.clear(0,0,0,1)
  G.origin()
  if Pokegear.__gen3uiOriginalDrawPanel then
    -- The native mode arrow belongs to Gold's original card strip. Our
    -- widescreen header is now the strip/selection UI, so suppress only that
    -- visual while capturing the live card. Input/card paging stays native.
    local oldModeArrow=self.drawModeArrow
    self.drawModeArrow=function() end
    -- Guarded: an unguarded error here used to skip drawModeArrow's restore
    -- and, worse, the setCanvas(oldCanvas)/pop below, leaving LÖVE's canvas
    -- and graphics-state stack pointed at this small offscreen card canvas
    -- for every draw call afterward -- a plausible source of a persistent
    -- warped/wrong-scale look on anything drawn later (including a 3D battle
    -- renderer's own scene), not just on this screen.
    pcall(Pokegear.__gen3uiOriginalDrawPanel,self)
    self.drawModeArrow=oldModeArrow
  end
  G.setCanvas(oldCanvas)
  G.pop()

  G.push("all")
  G.origin()

  -- Quiet translucent backdrop: same family as the existing Gen 3 menus while
  -- retaining Gold's world/battle context underneath where the engine allows it.
  G.setColor(0.025,0.045,0.060,0.94)
  G.rectangle("fill",0,0,winW,winH)

  local margin=math.max(24,math.floor(math.min(winW,winH)*0.045))
  local panelX=margin
  local panelY=margin
  local panelW=winW-margin*2
  local panelH=winH-margin*2

  -- Main cream body / slate frame, matching the mod's established Gen 3 shell.
  G.setColor(0.12,0.20,0.24,1)
  G.rectangle("fill",panelX+7,panelY+9,panelW,panelH,18,18)
  G.setColor(0.93,0.91,0.82,1)
  G.rectangle("fill",panelX,panelY,panelW,panelH,18,18)
  G.setColor(0.24,0.34,0.36,1)
  G.setLineWidth(3)
  G.rectangle("line",panelX,panelY,panelW,panelH,18,18)

  -- Header.
  local headerH=math.max(58,math.floor(panelH*0.105))
  G.setColor(0.12,0.27,0.38,1)
  G.rectangle("fill",panelX+4,panelY+4,panelW-8,headerH,14,14)

  printText("PokéGear",panelX+24,panelY+15,
    math.max(16,math.floor(headerH*0.36)),{0.96,0.96,0.90,1})

  -- Dynamic card tabs: visibleCards() already applies Gold's real engine flags.
  local cards=self.cards or {}
  local tabX=panelX+math.max(190,math.floor(panelW*0.27))
  local tabGap=8
  local available=panelX+panelW-18-tabX
  local tabW=(available-math.max(0,#cards-1)*tabGap)/math.max(1,#cards)
  local tabH=headerH-16

  for i,card in ipairs(cards) do
    local x=tabX+(i-1)*(tabW+tabGap)
    local selected=(i==(self.cardIndex or 1))
    G.setColor(selected and 0.16 or 0.84,
               selected and 0.34 or 0.83,
               selected and 0.48 or 0.75,1)
    G.rectangle("fill",x,panelY+10,tabW,tabH,8,8)
    if selected then
      G.setColor(0.96,0.37,0.16,1)
      G.rectangle("fill",x,panelY+10,4,tabH,4,4)
    end
    printText(tostring(card.label or card.id or ""):upper(),
      x,panelY+22,math.max(11,math.floor(headerH*0.23)),
      selected and {0.98,0.97,0.91,1} or {0.18,0.23,0.23,1},
      "center",tabW)

    if selected and #cards>1 then
      G.setColor(0.96,0.37,0.16,1)
      local cy=panelY+10+tabH/2
      G.polygon("fill",x+10,cy, x+18,cy-7, x+18,cy+7)
      G.polygon("fill",x+tabW-10,cy, x+tabW-18,cy-7, x+tabW-18,cy+7)
    end
  end

  -- Native live card viewport. Crop the original strip/indicator zone; the
  -- all map/phone/radio/clock content and their exact engine-driven state.
  local bodyX=panelX+22
  local bodyY=panelY+headerH+18
  local footerH=math.max(44,math.floor(panelH*0.075))
  local bodyW=panelW-44
  local bodyH=panelH-headerH-footerH-50

  G.setColor(0.10,0.17,0.18,1)
  G.rectangle("fill",bodyX-5,bodyY-5,bodyW+10,bodyH+10,10,10)
  G.setColor(0.82,0.82,0.72,1)
  G.rectangle("line",bodyX-5,bodyY-5,bodyW+10,bodyH+10,10,10)

  local srcY=24
  local srcH=120
  if not self.__gen3uiGearQuad then
    self.__gen3uiGearQuad=G.newQuad(0,srcY,160,srcH,160,144)
  end
  local scale=math.min(bodyW/160,bodyH/srcH)
  local dw=160*scale
  local dh=srcH*scale
  local dx=bodyX+(bodyW-dw)/2
  local dy=bodyY+(bodyH-dh)/2

  G.setColor(1,1,1,1)
  G.draw(canvas,self.__gen3uiGearQuad,dx,dy,0,scale,scale)

  -- Footer reflects native mode/input without taking ownership from update().
  local card=self.card and self:card() or cards[self.cardIndex or 1]
  local label=card and tostring(card.label or card.id or ""):upper() or "POKéGEAR"
  local hint
  if self.mode=="strip" then
    hint="LEFT / RIGHT: SELECT    A: OPEN    B: BACK"
  elseif card and card.id=="radio" then
    hint="UP / DOWN: TUNE    B: CARDS"
  elseif card and card.id=="phone" then
    hint="UP / DOWN: CONTACTS    A: SELECT    B: CARDS"
  elseif card and card.id=="map" then
    hint="D-PAD: MAP    B: CARDS"
  else
    hint="B: CARDS"
  end

  printText(label,panelX+24,panelY+panelH-footerH+10,
    math.max(11,math.floor(footerH*0.28)),{0.20,0.31,0.33,1})
  printText(hint,panelX+170,panelY+panelH-footerH+10,
    math.max(9,math.floor(footerH*0.24)),{0.32,0.39,0.39,1},
    "right",panelW-194)

  G.pop()
end


-- -------------------------------------------------------------------------
-- Pokémon Gold: core Gen 3-inspired menu presentation
-- -------------------------------------------------------------------------

function GoldCompat.menuPortraitShader()
  if GoldCompat.__menuPortraitShader~=nil then
    return GoldCompat.__menuPortraitShader or nil
  end

  local ok,shader=pcall(love.graphics.newShader,[[
    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
      vec4 px = Texel(tex, tc) * color;
      if (px.a > 0.0 && px.r > 0.985 && px.g > 0.985 && px.b > 0.985) {
        px.a = 0.0;
      }
      return px;
    }
  ]])

  GoldCompat.__menuPortraitShader = ok and shader or false
  return GoldCompat.__menuPortraitShader or nil
end

function GoldCompat.drawCleanResolvedPortrait(game,mon,x,y,w,h,kind)
  local G=love.graphics
  local shader=GoldCompat.menuPortraitShader()

  G.push("all")
  G.origin()
  if shader then G.setShader(shader) end
  local ok,drew=pcall(drawSelectedBattleSprite,game,mon,x,y,w,h,kind)
  G.setShader()
  G.pop()

  return ok and drew==true
end

function GoldCompat.genderSymbol(mon)
  local gender=mon and mon.gender
  if gender=="male" or gender=="female" then return gender end
  return nil
end

function GoldCompat.drawGenderIcon(x,y,size,gender)
  if gender~="male" and gender~="female" then return false end
  local G=love.graphics

  -- Compact modern Venus/Mars glyphs based on the user's reference:
  -- bold circular body, short stem/cross for female, diagonal arrow for male.
  size=math.max(8,math.min(22,size or 11))
  local line=math.max(1.4,size*0.16)
  local r=size*0.25
  local cx=x+r+1
  local cy=y+r+1

  G.push("all")
  G.origin()
  if G.setLineStyle then G.setLineStyle("smooth") end
  G.setLineWidth(line)

  if gender=="female" then
    G.setColor(0.95,0.20,0.52,1)
    G.circle("line",cx,cy,r)
    local stemTop=cy+r
    local stemBottom=cy+r+size*0.34
    G.line(cx,stemTop,cx,stemBottom)
    local crossY=cy+r+size*0.22
    G.line(cx-size*0.17,crossY,cx+size*0.17,crossY)
  else
    G.setColor(0.02,0.63,0.84,1)
    G.circle("line",cx,cy,r)

    local x1=cx+r*0.68
    local y1=cy-r*0.68
    local x2=cx+r+size*0.30
    local y2=cy-r-size*0.30
    G.line(x1,y1,x2,y2)

    local arm=size*0.19
    G.line(x2-arm,y2,x2,y2)
    G.line(x2,y2,x2,y2+arm)
  end

  G.setColor(1,1,1,1)
  G.pop()
  return true
end

function GoldCompat.prepareGoldStartMenu(self)
  -- Preserve Gold's actual menu entries/actions but normalize presentation-only
  -- labels that contain Gen 2 text-control tokens.
  if not self.__gen3uiDisplayItems then
    self.__gen3uiDisplayItems={}
  end
  for i,item in ipairs(self.items or {}) do
    local copy={}
    for k,v in pairs(item) do copy[k]=v end
    local label=tostring(copy.label or copy.value or "")
    if label:find("GEAR") or label:find("<PO>") or label:find("<KE>") then
      copy.label="PokéGear"
    end
    self.__gen3uiDisplayItems[i]=copy
  end

  self.__gen3uiOriginalItems=self.items
  self.items=self.__gen3uiDisplayItems

  local count=#(self.items or {})
  self.index=(self.list and self.list.index) or self.index or 1
  self.maxVisible=math.min(8,count)
  self.scroll=0
  if count>self.maxVisible then
    self.scroll=math.max(0,math.min(
      self.index-math.ceil(self.maxVisible/2),
      count-self.maxVisible))
  end
  State.activeStartMenu=self
end

function GoldCompat.drawGoldStartConfirm(self)
  if self.phase~="confirm" then return end
  local ox,oy,sc=finalCanvas()
  local G=love.graphics
  local x,y,w,h=26,48,108,50

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  G.setColor(0.05,0.05,0.05,0.35)
  G.rectangle("fill",x+2,y+2,w,h)
  G.setColor(0.08,0.08,0.07,1)
  G.rectangle("fill",x,y,w,h)
  G.setColor(0.99,0.985,0.95,1)
  G.rectangle("fill",x+2,y+2,w-4,h-4)
  drawUnifiedBorder(x,y,w,h,0)

  for i=1,2 do
    local yy=y+24+(i-1)*11
    if self.confirmChoice==i then
      G.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",x+65,yy-1,32,9,2)
    end
  end
  G.pop()

  finalText("Return to title screen?",x+8,y+8,3.8,
    {0.06,0.06,0.06,1},ox,oy,sc)

  finalText("YES",x+71,y+24,3.2,
    self.confirmChoice==1 and {1,1,1,1} or {0.06,0.06,0.06,1},
    ox,oy,sc)
  finalText("NO",x+71,y+35,3.2,
    self.confirmChoice==2 and {1,1,1,1} or {0.06,0.06,0.06,1},
    ox,oy,sc)
end

function GoldCompat.drawGoldPartyMenu(self,winW,winH)
  local party=self.party or {}
  local G=love.graphics
  local ox,oy,sc=partyLogicalCanvas()

  partyRenderOX,partyRenderOY,partyRenderScale=ox,oy,sc

  -- FOUND (v2.1.27): this was the actual reason Gen 2's party screen stayed a
  -- solid backdrop even after PartyMenu.isOpaque=false was set in v2.1.26.
  -- isOpaque only tells the engine it's safe to render the overworld BELOW
  -- this state -- it says nothing about what this state's OWN draw call
  -- paints on top of it, and this function (labeled "Exact Gen 1 Party
  -- screen foundation" -- a literal port of Gen 1's OLD, pre-hanging-panel
  -- layout) unconditionally filled the entire 160x144 canvas with an opaque
  -- backplate plus its own title-bar box, fully re-covering the overworld
  -- the engine had just been told it could render underneath. Gen 1's real
  -- drawPartyFinal already solved exactly this (see its own "No full-canvas
  -- backplate" comment) by dropping the fill entirely and drawing only the
  -- header text plus the individual floating card panels -- mirrored here.

  partyText("POKéMON",10,6,6,{0.06,0.06,0.06,1})

  if #party==0 then
    partyText("No POKéMON!",12,62,6,{0.06,0.06,0.06,1})
    return
  end

  local selected=math.max(1,math.min(self.index or 1,#party))
  local mon=party[selected]
  local def=mon and self.pokemon and self.pokemon[mon.species]

  -- ---------------------------------------------------------- selected detail
  local lx,ly,lw,lh=4,23,74,101
  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  partySlotPanel(lx,ly,lw,lh,true)

  -- Large selected portrait follows the exact same resolved battle-art path as
  -- Gen 1 Party/Pokédex. This is what keeps Battle Arts / configured sprite
  -- packages consistent outside battle. Native Gold icon is only a fallback.
  if mon then
    G.pop()
    local drewResolved=false
    G.push("all")
    G.origin()
    drewResolved=GoldCompat.drawCleanResolvedPortrait(
      self.game,mon,
      ox+(lx+7)*sc,oy+(ly+14)*sc,31*sc,28*sc,"summary")
    G.pop()
    G.push("all")
    G.translate(ox,oy)
    G.scale(sc,sc)
    if not drewResolved then
      G.push("all")
      G.translate(lx+9,ly+15)
      G.scale(1.8,1.8)
      self:drawIcon(mon,0,0)
      G.pop()
    end
  end
  G.pop()

  if mon then
    local name=mon.isEgg and "EGG"
      or tostring(mon.nickname or (def and def.name) or mon.species or "POKéMON")
    partyText(name,lx+7,ly+5,5.2,{0.06,0.06,0.06,1})
    local gender=GoldCompat.genderSymbol(mon)

    if not mon.isEgg then
      local lv="Lv."..tostring(mon.level or "?")
      partyText(lv,lx+lw-7-partyTextWidth(lv,4),ly+6,4,
        {0.06,0.06,0.06,1})

      -- HP
      local hpMax=math.max(1,mon.maxHp or (mon.stats and mon.stats.hp) or 1)
      local hpNow=mon.hp or 0
      local hpText=tostring(hpNow).."/"..tostring(hpMax)
      local hpY=ly+44
      local hpValueX=lx+lw-7-partyTextWidth(hpText,3)
      local hpBarX=lx+21
      local hpBarW=math.max(17,hpValueX-hpBarX-3)

      partyText("HP",lx+9,hpY,3,{0.08,0.08,0.08,1})

      G.push("all")
      G.translate(ox,oy)
      G.scale(sc,sc)
      local ratio=math.max(0,math.min(1,hpNow/hpMax))
      G.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",hpBarX,hpY+1,hpBarW,4,1.5)
      G.setColor(0.78,0.76,0.63,1)
      roundedRect("fill",hpBarX+1,hpY+2,hpBarW-2,2,1)
      if hpNow>0 then
        local r,gg,b,a=hpColor(ratio)
        G.setColor(r,gg,b,a)
        roundedRect("fill",hpBarX+1,hpY+2,
          math.max(1,(hpBarW-2)*ratio),2,1)
      end
      G.pop()

      partyText(hpText,hpValueX,hpY,3,{0.08,0.08,0.08,1})

      -- Selected-card gender gets its own readable slot between HP and EXP.
      -- This keeps it away from the Pokémon name and makes the symbol much
      -- easier to discern on handheld/mobile displays.
      if gender then
        pcall(GoldCompat.drawGenderIcon,
          ox+(lx+14)*sc,oy+(ly+52)*sc,12,gender)
      end

      local rowData=self.rowFor and self.rowFor(mon) or nil
      if rowData and rowData.status then
        partyText(rowData.status,lx+9,ly+49,2.8,{0.44,0.14,0.14,1})
      end

      -- EXP sits beneath the HP/status area, leaving more room below for moves
      -- and a properly padded stat footer.
      partyText("EXP",lx+9,ly+56,2.5,{0.34,0.45,0.50,1})
      G.push("all")
      G.translate(ox,oy)
      G.scale(sc,sc)
      local expRatio=partyExpRatio(self.game,mon)
      G.setColor(0.10,0.18,0.24,1)
      roundedRect("fill",lx+21,ly+57,lw-29,4,1.5)
      G.setColor(0.14,0.28,0.38,1)
      roundedRect("fill",lx+22,ly+58,lw-31,2,1)
      if expRatio>0 then
        G.setColor(0.08,0.48,0.96,1)
        roundedRect("fill",lx+22,ly+58,(lw-31)*expRatio,2,1)
      end
      G.pop()

      -- Four-move horizontal strip, matching the mature Gen 1 Party workflow.
      -- This creates one stable move region for normal viewing, TM replacement,
      -- and mid-battle MoveLearn selection instead of changing geometry by flow.
      --
      -- The TM replacement/MoveLearn part of that plan was never actually
      -- wired up: canIntegrateMoveLearn/State.activeTMParty only ever got set
      -- from Gen 1's src/ui/PartyMenu.lua, never this class, so Gen 2's TM/HM
      -- teach flow fell straight through to fully native rendering for the
      -- move-replace step regardless of this comment's intent (see the new
      -- PartyMenu.new wrap above, next to __gen3uiVisualPatched, which now
      -- sets State.activeTMParty here too). GoldCompat.drawPartyMoveReplace
      -- is Gen 1's own panel (a vertical 4-row list, not this grid) but it
      -- already repaints this whole region opaquely on its own, so reusing it
      -- outright is exactly "the same logic our Gen 1 TM/HM flow does" per
      -- the user's own request, not a mismatched bolt-on.
      local integratedLearn=State.activeMoveLearn
      local gen2Deleter=State.activeGen2MoveDeleter
      if integratedLearn and integratedLearn.selecting
          and integratedLearn.mon==mon
          and canIntegrateMoveLearn(self.game,integratedLearn) then
        GoldCompat.drawPartyMoveReplace(self.game,mon,lx,ly,lw,lh,integratedLearn)
      elseif gen2Deleter and gen2Deleter.mon==mon then
        -- Gen 2's real MoveDeleter has no intermediate "announcing" phase of
        -- its own (that's the separate TextBox chain in Game2:learnMoveOn) --
        -- once this class exists at all with opts.layout=="forget", it IS the
        -- picking step, so no extra .selecting-style gate is needed here the
        -- way Gen 1's single combined MoveLearnMenu class requires one.
        GoldCompat.drawPartyMoveReplace(self.game,mon,lx,ly,lw,lh,{
          mon=mon,
          newMoveId=gen2Deleter.__gen3uiNewMoveId,
          index=gen2Deleter.row,
        })
      else
        local moves=mon.moves or {}
        local stripX=lx+6
        local stripY=ly+62
        local stripW=lw-12
        local moveGap=1
        local moveW=(stripW-moveGap*3)/4
        local moveH=20

        G.push("all")
        G.translate(ox,oy)
        G.scale(sc,sc)
        G.setColor(0.70,0.68,0.59,1)
        G.rectangle("fill",lx+7,ly+61,lw-14,1)

        for i=1,4 do
          local cx=stripX+(i-1)*(moveW+moveGap)
          G.setColor(0.965,0.95,0.88,1)
          roundedRect("fill",cx,stripY,moveW,moveH,1.2)
          G.setColor(0.74,0.71,0.61,1)
          roundedRect("line",cx,stripY,moveW,moveH,1.2)
        end
        G.pop()

        for i=1,4 do
          local entry=moves[i]
          local cx=stripX+(i-1)*(moveW+moveGap)
          local moveName=partyMoveName(self.game,entry)
          local pp=partyMovePP(self.game,entry)

          -- Fit the complete move name to the cell rather than truncating it.
          local nameSize=2.35
          while nameSize>1.45 and partyTextWidth(moveName,nameSize)>moveW-3 do
            nameSize=nameSize-0.12
          end

          partyText(moveName,cx+1.5,stripY+4,nameSize,
            {0.06,0.06,0.06,1},"center",moveW-3)
          if pp~="" then
            partyText(pp,cx+1.5,stripY+13,1.8,
              {0.24,0.24,0.21,1},"center",moveW-3)
          end
        end

        -- Gen 2 stat footer. Gold has split Special, so preserve both values.
        local stats={
          {"ATK",partyStat(mon,"attack","atk")},
          {"DEF",partyStat(mon,"defense","def")},
          {"SPD",partyStat(mon,"speed","spd")},
          {"SPA",partyStat(mon,"specialAttack","spAtk","special")},
          {"SPD",partyStat(mon,"specialDefense","spDef","special")},
        }
        local statY=ly+lh-15
        local innerX=lx+6
        local innerW=lw-12
        local colW=innerW/5

        G.push("all")
        G.translate(ox,oy)
        G.scale(sc,sc)
        G.setColor(0.74,0.72,0.64,1)
        G.rectangle("fill",lx+7,statY-1,lw-14,1)
        G.pop()

        for i,s in ipairs(stats) do
          local cx=innerX+(i-1)*colW
          local label=s[1]
          local value=tostring(s[2])
          partyText(label,cx+(colW-partyTextWidth(label,1.7))/2,statY,1.7,
            {0.25,0.25,0.22,1})
          partyText(value,cx+(colW-partyTextWidth(value,2.4))/2,statY+4,2.4,
            {0.06,0.06,0.06,1})
        end
      end

      if mon.item and mon.item~=0 and mon.item~="" then
        local itemName=tostring(mon.item)
        local idef=self.items and self.items[mon.item]
        if idef and idef.name then itemName=idef.name end
        if #itemName>13 then itemName=itemName:sub(1,12).."." end
        partyText("HELD "..itemName,lx+31,ly+50,1.9,{0.34,0.34,0.30,1})
      end
    else
      partyText("EGG",lx+9,ly+49,4,{0.18,0.18,0.16,1})
    end
  end

  -- --------------------------------------------------------------- party list
  local rx,rw=80,76
  local slotH,gap=16,1

  for i,m in ipairs(party) do
    if i>6 then break end
    local yy=23+(i-1)*(slotH+gap)
    local isSelected=i==selected
    local d=self.pokemon and self.pokemon[m.species]

    G.push("all")
    G.translate(ox,oy)
    G.scale(sc,sc)

    -- Previously an inline near-duplicate of partySlotPanel with its own
    -- flat near-black frame (same "distracting black border" bug fixed
    -- there in v2.1.29, just re-typed a second time here). Reuse the one
    -- shared, now-softened panel for both rows instead of drifting further.
    partySlotPanel(rx,yy,rw,slotH,isSelected)

    local drewRowPortrait=false
    if not m.isEgg then
      drewRowPortrait=GoldCompat.drawCleanResolvedPortrait(self.game,m,
        ox+(rx+3)*sc,oy+(yy+1)*sc,14*sc,14*sc,"summary")
    end
    if not drewRowPortrait then
      G.push("all")
      G.translate(rx+2,yy)
      self:drawIcon(m,0,0)
      G.pop()
    end
    G.pop()

    local n=m.isEgg and "EGG"
      or tostring(m.nickname or (d and d.name) or m.species or "POKéMON")
    if #n>10 then n=n:sub(1,9).."." end
    partyText(n,rx+19,yy+1,3.3,{0.06,0.06,0.06,1})
    local rowGender=GoldCompat.genderSymbol(m)
    if rowGender and not m.isEgg then
      local gx=math.min(rx+20+partyTextWidth(n,3.3),rx+rw-27)
      pcall(GoldCompat.drawGenderIcon,
        ox+gx*sc,oy+(yy+2.7)*sc,8,rowGender)
    end

    if not m.isEgg then
      local lv="Lv."..tostring(m.level or "?")
      partyText(lv,rx+rw-4-partyTextWidth(lv,3),yy+1,3,
        {0.06,0.06,0.06,1})

      -- TM/HM target picking (opts.tmhm, wired up above in installGoldOverlays
      -- alongside the Gen 1 party's own equivalent) swaps this row's HP bar
      -- for an ABLE/NOT ABLE readout, exactly matching Gen 1's drawPartyFinal.
      --
      -- FOUND (v2.1.31): user report -- every row shows ABLE, even a mon that
      -- can't learn the move. `self:tmhmAble(mon)` is the real native
      -- src/ui/gen2/PartyMenu.lua method, confirmed by reading it directly --
      -- but it does NOT return a boolean the way its name suggests. It
      -- returns a LOCALIZED STRING either way (`Strings(ABLE_LABEL)` or
      -- `Strings(NOT_ABLE_LABEL)`), and nil only when `self.tmhm.move` is
      -- missing entirely. `self.tmhmAble and self:tmhmAble(m) or false` was
      -- treating that string's mere truthiness as the answer -- both real
      -- return values are non-nil strings, so `canLearn` was true 100% of
      -- the time whenever a TM/HM teach was actually in progress. `ABLE_LABEL`/
      -- `NOT_ABLE_LABEL` are locals inside that module, not reachable from
      -- here to compare against, so this now re-derives the same boolean the
      -- real method computes internally (species.tmhm list membership)
      -- directly -- identical logic to Gen 1's own hand-derived version just
      -- above in drawPartyFinal, which never had this bug because it never
      -- had a same-named native helper to be misled by in the first place.
      if self.tmhm then
        local canLearn=false
        local moveId=self.tmhm.move
        if moveId then
          local species=self.pokemon and self.pokemon[m.species]
          for _,id in ipairs((species and species.tmhm) or {}) do
            if id==moveId then canLearn=true break end
          end
        end
        local ableText=canLearn and "ABLE" or "NOT ABLE"
        local ableW=partyTextWidth(ableText,3)
        partyText(ableText,rx+rw-5-ableW,yy+9,3,
          canLearn and {0.16,0.42,0.20,1} or {0.46,0.14,0.12,1})
        goto continuePartyRow
      end

      local mhp=math.max(1,m.maxHp or (m.stats and m.stats.hp) or 1)
      local ratio=math.max(0,math.min(1,(m.hp or 0)/mhp))

      G.push("all")
      G.translate(ox,oy)
      G.scale(sc,sc)
      G.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",rx+19,yy+9,39,4,1.5)
      G.setColor(0.78,0.76,0.63,1)
      roundedRect("fill",rx+20,yy+10,37,2,1)
      if (m.hp or 0)>0 then
        local r,gg,b,a=hpColor(ratio)
        G.setColor(r,gg,b,a)
        roundedRect("fill",rx+20,yy+10,math.max(1,37*ratio),2,1)
      end
      G.pop()

      local hp=tostring(m.hp or 0).."/"..tostring(mhp)
      partyText(hp,rx+rw-4-partyTextWidth(hp,2.4),yy+9,2.4,
        {0.18,0.18,0.16,1})

      ::continuePartyRow::
    end
  end

  -- -------------------------------------------------------------- footer/prompt
  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  local fy=127
  G.setColor(0.08,0.08,0.07,1)
  G.rectangle("fill",4,fy,152,13)
  G.pop()

  local prompt=self.switchFrom and "Move to where?"
    or tostring(self.prompt or "Choose a POKéMON.")
  local activeForget=State.activeGen2MoveDeleter
  if activeForget and party[selected] and activeForget.mon==party[selected] then
    prompt="Choose a move to forget."
  end
  prompt=prompt:gsub("<PK><MN>","POKéMON")
  if #prompt>34 then prompt=prompt:sub(1,33).."." end
  partyText(prompt,8,130,3.6,{1,1,1,1})

  -- Gold's native submenu state, themed to match the Gen 1 party screen.
  if self.submenu and self.submenu.items then
    local count=#self.submenu.items
    local w=48
    local h=count*10+6
    local x=108
    local y=math.max(24,124-h)

    G.push("all")
    G.translate(ox,oy)
    G.scale(sc,sc)
    G.setColor(0.08,0.08,0.07,1)
    G.rectangle("fill",x,y,w,h)
    G.setColor(0.99,0.985,0.95,1)
    G.rectangle("fill",x+2,y+2,w-4,h-4)
    drawUnifiedBorder(x,y,w,h,0)

    for i=1,count do
      local yy=y+3+(i-1)*10
      if i==self.submenu.index then
        G.setColor(0.10,0.10,0.09,1)
        G.rectangle("fill",x+4,yy,w-8,9)
      end
    end
    G.pop()

    for i,item in ipairs(self.submenu.items) do
      local yy=y+3+(i-1)*10
      partyText(item.label,x+8,yy+1,3,
        i==self.submenu.index and {1,1,1,1} or {0.06,0.06,0.06,1})
    end
  end
end

function GoldCompat.dexMapLabel(data,mapId)
  local map=data and data.gen2Maps and data.gen2Maps[mapId]
  if map then
    if map.name and tostring(map.name)~="" then return tostring(map.name) end
    local landmarkIndex=map.landmark
    if landmarkIndex then
      local Nests=GoldCompat.engineModule("src.core.gen2.Nests")
      if Nests and type(Nests.landmark)=="function" then
        local landmark=Nests.landmark(data,landmarkIndex)
        if landmark then
          local name=landmark.name or landmark.label or landmark.title
          if not name and type(landmark.lines)=="table" then
            name=table.concat(landmark.lines," ")
          end
          if name and tostring(name)~="" then return tostring(name) end
        end
      end
    end
  end
  return tostring(mapId or "UNKNOWN")
    :gsub("^MAP_",""):gsub("_"," "):gsub("%s+"," ")
end

function GoldCompat.dexSlotHasSpecies(slots,species)
  if type(slots)~="table" then return false end
  -- direct list: water/fish/tree
  for _,slot in ipairs(slots) do
    if type(slot)=="table" and slot.species==species then return true end
  end
  -- time-of-day map: grass
  for _,list in pairs(slots) do
    if type(list)=="table" then
      for _,slot in ipairs(list) do
        if type(slot)=="table" and slot.species==species then return true end
      end
    end
  end
  return false
end

function GoldCompat.dexCatchLocations(self,species)
  local data=self and self.data or {}
  local enc=data.gen2Encounters or {}
  local byMap={}

  local function add(mapId,method)
    if not mapId or not method then return end
    local row=byMap[mapId]
    if not row then
      row={map=mapId,name=GoldCompat.dexMapLabel(data,mapId),methods={},seen={}}
      byMap[mapId]=row
    end
    if not row.seen[method] then
      row.seen[method]=true
      row.methods[#row.methods+1]=method
    end
  end

  local function grassTable(tbl,label)
    for mapId,entry in pairs(tbl or {}) do
      local times={}
      for _,tod in ipairs({"MORN","DAY","NITE"}) do
        if GoldCompat.dexSlotHasSpecies(entry and entry.slots
            and entry.slots[tod],species) then
          times[#times+1]=tod
        end
      end
      if #times>0 then
        add(mapId,label.." "..table.concat(times,"/"))
      end
    end
  end
  grassTable(enc.grass,"GRASS")
  grassTable(enc.swarmGrass,"SWARM GRASS")

  for mapId,entry in pairs(enc.water or {}) do
    if GoldCompat.dexSlotHasSpecies(entry and entry.slots,species) then
      add(mapId,"SURF")
    end
  end
  for mapId,entry in pairs(enc.swarmWater or {}) do
    if GoldCompat.dexSlotHasSpecies(entry and entry.slots,species) then
      add(mapId,"SWARM SURF")
    end
  end

  -- Fishing groups are selected by each map header's fishGroup.
  for mapId,map in pairs(data.gen2Maps or {}) do
    local group=map and map.fishGroup
    local fish=group and enc.fishGroups and enc.fishGroups[group]
    if fish then
      if GoldCompat.dexSlotHasSpecies(fish.old,species) then
        add(mapId,"OLD ROD")
      end
      if GoldCompat.dexSlotHasSpecies(fish.good,species) then
        add(mapId,"GOOD ROD")
      end
      if GoldCompat.dexSlotHasSpecies(fish.super,species) then
        add(mapId,"SUPER ROD")
      end
    end
  end

  for mapId,setId in pairs(enc.trees or {}) do
    local set=enc.treeSets and enc.treeSets[setId]
    if set then
      if GoldCompat.dexSlotHasSpecies(set.common,species) then
        add(mapId,"HEADBUTT")
      end
      if GoldCompat.dexSlotHasSpecies(set.rare,species) then
        add(mapId,"HEADBUTT RARE")
      end
    end
  end

  for mapId,setId in pairs(enc.rocks or {}) do
    local set=enc.treeSets and enc.treeSets[setId]
    if set and (GoldCompat.dexSlotHasSpecies(set.common,species)
        or GoldCompat.dexSlotHasSpecies(set.rare,species)) then
      add(mapId,"ROCK SMASH")
    end
  end

  for _,slot in ipairs(enc.bugContest or {}) do
    if slot and slot.species==species then
      add("NATIONAL_PARK","BUG CONTEST")
      break
    end
  end

  -- Roaming Pokémon show their CURRENT catchable map.
  for _,slot in ipairs((self.save and self.save.roamers) or {}) do
    if slot and slot.species==species and slot.map then
      add(slot.map,"ROAMING")
    end
  end

  local rows={}
  for _,row in pairs(byMap) do
    table.sort(row.methods)
    row.method=table.concat(row.methods," / ")
    rows[#rows+1]=row
  end
  table.sort(rows,function(a,b)
    if a.name==b.name then return a.method<b.method end
    return a.name<b.name
  end)
  return rows
end

function GoldCompat.drawGoldDexLocations(self,row)
  local ox,oy,sc=safeFullCanvas()
  local G=love.graphics
  local source=self.pokemon and self.pokemon[row.species]
  local dexEntry=self.dex and self.dex.entries and self.dex.entries[row.species]
  local name=tostring((source and source.name) or row.species or "POKéMON")
  local locations=GoldCompat.dexCatchLocations(self,row.species)

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  -- Gen 2 Pokédex subpages follow the same hanging ownership as the main
  -- contents/data views: only the actual cards paint; the map stays visible
  -- everywhere else.

  G.setColor(0.08,0.08,0.07,1)
  G.rectangle("fill",4,4,152,17)
  G.setColor(0.99,0.985,0.955,1)
  G.rectangle("fill",5,5,150,15)

  G.setColor(0.12,0.12,0.11,1)
  roundedRect("fill",4,25,152,103,3)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",6,27,148,99,2)
  setCurrentBorderColor(1)
  roundedRect("line",7,28,146,97,2)

  G.setColor(0.08,0.08,0.07,1)
  G.rectangle("fill",4,132,152,8)
  G.pop()

  finalText("CATCH LOCATIONS",9,8,4.7,{0.06,0.06,0.06,1},ox,oy,sc)
  finalText(name,11,32,4.0,{0.07,0.07,0.07,1},ox,oy,sc)
  if dexEntry and dexEntry.dex then
    finalText(("No. %03d"):format(tonumber(dexEntry.dex) or 0),
      126,32,2.7,{0.35,0.35,0.32,1},ox,oy,sc,"right",22)
  end

  self.__gen3uiDexLocationRows=locations
  local visible=7
  local maxScroll=math.max(0,#locations-visible)
  self.__gen3uiDexLocationScroll=math.max(0,
    math.min(self.__gen3uiDexLocationScroll or 0,maxScroll))
  local first=(self.__gen3uiDexLocationScroll or 0)+1

  if #locations==0 then
    finalText("NO WILD LOCATIONS FOUND",12,58,3.25,
      {0.34,0.34,0.31,1},ox,oy,sc)
  else
    for i=0,visible-1 do
      local loc=locations[first+i]
      if not loc then break end
      local yy=45+i*10.2
      -- Keep the location column compact and visually stable. Long names
      -- are slightly smaller and get a wider dedicated column so they never
      -- stack or collide with neighboring rows.
      local locName=tostring(loc.name or "")
      local locSize=(#locName>=13) and 2.35 or 2.65
      finalText(locName,12,yy,locSize,{0.08,0.08,0.08,1},
        ox,oy,sc,"left",66)
      finalText(loc.method,82,yy,2.30,{0.31,0.31,0.28,1},
        ox,oy,sc,"left",64)
    end
    if first>1 then
      finalText("▲",146,42,2.7,{0.28,0.28,0.25,1},ox,oy,sc)
    end
    if first+visible-1<#locations then
      finalText("▼",146,116,2.7,{0.28,0.28,0.25,1},ox,oy,sc)
    end
  end

  finalText("↑/↓ SCROLL",9,134,1.95,
    {0.80,0.80,0.76,1},ox,oy,sc)
  local dexBackLabel="A/B: POKéDEX"
  local dexBackSize=2.05
  local dexBackX=151-finalTextWidth(dexBackLabel,dexBackSize,sc)
  finalText(dexBackLabel,dexBackX,134,dexBackSize,
    {0.96,0.95,0.90,1},ox,oy,sc)
  return true
end

function GoldCompat.drawGoldPokedex(self,winW,winH)
  local row=self.current and self:current() or nil

  if self.view=="list" then
    -- Adapt Gold's real sorted rows/cursor/caught flags to the mature Gen 1
    -- Pokédex presentation. Input, mode switching and entry opening stay Gold.
    local items={}
    local index={}
    for i,r in ipairs(self.rows or {}) do
      items[i]={label=r.species}

      local source=self.pokemon and self.pokemon[r.species]
      local dexEntry=self.dex and self.dex.entries and self.dex.entries[r.species]
      local def={}
      if type(source)=="table" then
        for k,v in pairs(source) do def[k]=v end
      end

      def.id=r.species
      def.name=(source and source.name) or r.species
      def.dex=(dexEntry and dexEntry.dex) or r.dex or i
      def.dexEntry={
        kind=dexEntry and dexEntry.kind,
        gen2Height=dexEntry and dexEntry.height,
        gen2Weight=dexEntry and dexEntry.weight,
      }

      index[i]={id=r.species,def=def,dex=def.dex}
    end

    local facade={
      items=items,
      index=self.index or 1,
      __gen3uiDexIndex=index,
      __gen2Dex=true,
    }

    -- DexUI expects save.pokedex.owned; Gold calls the same set `caught`.
    local game=self.game
    local proxy=setmetatable({
      data=game.data,
      __gen2PokedexMenu=self,
      save=setmetatable({
        pokedex={
          seen=(self.save and self.save.pokedex and self.save.pokedex.seen) or {},
          owned=(self.save and self.save.pokedex and
            (self.save.pokedex.caught or self.save.pokedex.owned)) or {},
        }
      },{__index=game.save})
    },{__index=game})

    return DexUI.draw(proxy,facade)
  end

  if self.view=="locations" and row then
    return GoldCompat.drawGoldDexLocations(self,row)
  end

  if self.view=="entry" and row then
    local source=self.pokemon and self.pokemon[row.species]
    local dexEntry=self.dex and self.dex.entries and self.dex.entries[row.species]

    if source and dexEntry then
      -- Shallow display definition only; never mutate Gold's data tables.
      local def={}
      for k,v in pairs(source) do def[k]=v end
      def.id=row.species
      def.dex=dexEntry.dex
      def.dexEntry={
        kind=dexEntry.kind,
        gen2Height=dexEntry.height,
        gen2Weight=dexEntry.weight,
        text=nil,
      }

      local proxy=setmetatable({
        data=self.game.data,
        __gen2PokedexMenu=self,
        save=setmetatable({
          pokedex={owned={[row.species]=row.caught==true}}
        },{__index=self.game.save})
      },{__index=self.game})

      -- Draw the established Gen 1 entry card, then replace its description
      -- region with Gold's real two-page dex text.
      DexUI.drawEntry(proxy,{def=def,forceOwned=row.caught==true})

      local ox,oy,sc=safeFullCanvas()
      -- Our UI has one complete DATA page. Gold's two cartridge-sized text
      -- chunks are joined and rewrapped for the larger modern card.
      local raw=table.concat({
        tostring(dexEntry.text or ""),
        tostring(dexEntry.text2 or "")
      }," ")
      local clean=GoldCompat.cleanWrappedText(raw)

      local G=love.graphics
      G.push("all")
      G.translate(ox,oy)
      G.scale(sc,sc)
      G.setColor(0.99,0.985,0.95,1)

      -- The shared entry card already printed a bare ENTRY label. Clear the
      -- complete description/label region before drawing Gold's page counter
      -- so ENTRY never appears double-layered.
      G.rectangle("fill",10,75,138,48)
      G.pop()

      finalText("ENTRY",12,78,3.2,{0.38,0.38,0.35,1},ox,oy,sc)

      local entrySize=3.55
      local f=font(entrySize*UI_TEXT_SCALE*GoldCompat.userTextScale())
      local _,wrapped=f:getWrap(clean,132)
      for i=1,math.min(5,#wrapped) do
        finalText(wrapped[i],12,87+(i-1)*7.4,entrySize,
          {0.08,0.08,0.08,1},ox,oy,sc,"left",132)
      end

      -- DexUI's shared detail renderer already drew its own footer controls.
      -- Erase that footer here before painting the Gold DATA controls; without
      -- this the two legends occupy the exact same pixels and look "bold" or
      -- scrambled regardless of text scaling.
      G.push("all")
      G.translate(ox,oy)
      G.scale(sc,sc)
      G.setColor(0.08,0.08,0.08,1)
      G.rectangle("fill",4,132,152,8)
      G.pop()

      local backLabel="B: BACK"
      local backSize=2.05
      local backX=151-finalTextWidth(backLabel,backSize,sc)
      safeFooterText("A: CATCH LOCATIONS",9,134,2.05,
        {0.96,0.95,0.90,1},ox,oy,sc,104)
      finalText(backLabel,backX,134,backSize,
        {0.96,0.95,0.90,1},ox,oy,sc)
      return
    end
  end

  -- Gen 2-only views still use Gold's real renderer inside our widescreen shell
  -- until dedicated visual translations are added.
  local PokedexMenu=GoldCompat.requiredEngineModule("src.ui.gen2.PokedexMenu")
  local G=love.graphics
  winW=winW or G.getWidth()
  winH=winH or G.getHeight()

  if not self.__gen3uiDexCanvas then
    local ok,canvas=pcall(G.newCanvas,160,144)
    if ok then
      self.__gen3uiDexCanvas=canvas
      if canvas.setFilter then pcall(canvas.setFilter,canvas,"nearest","nearest") end
    end
  end

  local canvas=self.__gen3uiDexCanvas
  if not canvas or not PokedexMenu.__gen3uiOriginalDrawPanel then
    return PokedexMenu.__gen3uiOriginalDrawWidescreen(self,winW,winH)
  end

  local oldCanvas=G.getCanvas()
  G.push("all")
  G.setCanvas(canvas)
  G.clear(0,0,0,1)
  G.origin()
  -- Guarded: see the matching Pokegear capture above -- an unguarded error
  -- here used to skip setCanvas(oldCanvas)/pop, leaving LÖVE's canvas and
  -- graphics-state stack pointed at this small offscreen dex canvas for
  -- every draw call afterward.
  pcall(PokedexMenu.__gen3uiOriginalDrawPanel,self)
  G.setCanvas(oldCanvas)
  G.pop()

  G.push("all")
  G.origin()
  G.setColor(0.94,0.93,0.87,1)
  G.rectangle("fill",0,0,winW,winH)

  local margin=24
  local x,y=margin,margin
  local w,h=winW-margin*2,winH-margin*2
  G.setColor(0.08,0.08,0.07,1)
  G.rectangle("fill",x,y,w,h)
  G.setColor(0.99,0.985,0.95,1)
  G.rectangle("fill",x+4,y+4,w-8,h-8)
  G.setColor(0.18,0.17,0.15,1)
  G.setLineWidth(2)
  G.rectangle("line",x+4,y+4,w-8,h-8)

  local bodyX=x+18
  local bodyY=y+54
  local bodyW=w-36
  local bodyH=h-84
  local scale=math.min(bodyW/160,bodyH/144)
  local dw,dh=160*scale,144*scale
  G.setColor(1,1,1,1)
  G.draw(canvas,bodyX+(bodyW-dw)/2,bodyY+(bodyH-dh)/2,0,scale,scale)
  G.pop()

  printText("POKéDEX  "..tostring(self.view or ""):upper(),
    x+18,y+14,16,{0.06,0.06,0.06,1})
end


function GoldCompat.cleanWrappedText(text)
  local clean=tostring(text or "")
    :gsub("<NEXT>"," ")
    :gsub("\\v"," ")
    :gsub("\\f"," ")
    :gsub("%s+"," ")
    :gsub("^%s+","")
    :gsub("%s+$","")

  -- Gen 2's source strings sometimes encode line-break hyphenation such as
  -- "pro- tects" / "Be- cause". Once presented in a widescreen UI those
  -- cartridge-era breaks look like accidental word splitting, so rejoin only
  -- alphabetic hyphen+whitespace+alphabetic sequences.
  local previous
  repeat
    previous=clean
    clean=clean:gsub("(%a)%-%s+(%a)","%1%2")
  until clean==previous

  return clean
end

function GoldCompat.summaryDexEntry(summary)
  local mon=summary and summary.mon
  local dex=summary and summary.game and summary.game.data
      and summary.game.data.gen2Pokedex
  return mon and dex and dex.entries and dex.entries[mon.species] or nil
end

function GoldCompat.summaryTypeNames(summary)
  if summary and type(summary.typeNames)=="function" then
    local ok,a,b=pcall(summary.typeNames,summary)
    if ok then return a,b end
  end
  local mon=summary and summary.mon
  local def=summary and summary.pokemon and mon
      and summary.pokemon[mon.species]
  local types=(mon and mon.types) or (def and def.types) or {}
  return tostring(types[1] or "N/A"),types[2] and tostring(types[2]) or nil
end

function GoldCompat.summaryMoveDef(summary,entry)
  if not entry then return nil end
  local id=type(entry)=="table" and (entry.id or entry.move) or entry
  -- Native Gen 2 SummaryMenu instances carry their own move-dex reference
  -- as self.moves; Gen 1's native SummaryMenu does not, so fall back to the
  -- shared game.data.moves table (this is what lets drawGoldMoveManager
  -- serve both generations' Move Manager unchanged).
  local moves=summary and summary.moves
  if not moves then
    local game=summary and summary.game
    moves=game and game.data and game.data.moves
  end
  return moves and moves[id] or nil
end

function GoldCompat.summaryMoveName(summary,entry)
  local def=GoldCompat.summaryMoveDef(summary,entry)
  local id=type(entry)=="table" and (entry.id or entry.move) or entry
  return tostring((def and def.name) or id or "---")
end

function GoldCompat.summaryExpRatio(summary)
  local mon=summary and summary.mon
  local def=summary and summary.pokemon and mon
      and summary.pokemon[mon.species]
  if not (mon and def and mon.level and mon.experience) then return 0 end
  if mon.level>=100 then return 1 end

  local Mon=GoldCompat.engineModule("src.battle.gen2.Mon")
  if not Mon then return 0 end
  local growth=summary.growth and summary:growth()
  if not growth then return 0 end

  local floor=Mon.experienceForLevel(growth,mon.level)
  local nextFloor=Mon.experienceForLevel(growth,mon.level+1)
  return math.max(0,math.min(1,
    (mon.experience-floor)/math.max(1,nextFloor-floor)))
end

function GoldCompat.drawGoldSummaryBase(summary,title)
  local G=love.graphics
  local ox,oy,sc=safeFullCanvas()

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)

  G.setColor(0.94,0.93,0.87,1)
  G.rectangle("fill",0,0,160,144)

  -- Header.
  G.setColor(0.08,0.08,0.08,1)
  G.rectangle("fill",4,4,152,17)
  G.setColor(0.99,0.985,0.955,1)
  G.rectangle("fill",5,5,150,15)

  -- Main cards - same geometry family as the Gen 1 summary.
  G.setColor(0.12,0.12,0.11,1)
  roundedRect("fill",4,33,65,95,3)
  roundedRect("fill",72,33,84,95,3)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",6,35,61,91,2)
  roundedRect("fill",74,35,80,91,2)

  setCurrentBorderColor(1)
  roundedRect("line",7,36,59,89,2)
  roundedRect("line",75,36,78,89,2)

  -- Footer.
  G.setColor(0.08,0.08,0.08,1)
  G.rectangle("fill",4,132,152,8)

  -- Three native Gold pages as explicit tabs.
  local tabs={"INFO","MOVES","STATS"}
  local page=math.max(1,math.min(3,summary.page or 1))
  local tx=75
  local tw=25
  for i,label in ipairs(tabs) do
    local x=tx+(i-1)*26
    if i==page then
      G.setColor(0.11,0.28,0.38,1)
      roundedRect("fill",x,23,tw,8,1.5)
    else
      G.setColor(0.84,0.82,0.74,1)
      roundedRect("fill",x,23,tw,8,1.5)
    end
  end
  G.pop()

  finalText(title or "POKéMON SUMMARY",
    9,8,4.8,{0.06,0.06,0.06,1},ox,oy,sc)

  for i,label in ipairs({"INFO","MOVES","STATS"}) do
    finalText(label,75+(i-1)*26,24.7,2.45,
      i==(summary.page or 1) and {0.98,0.97,0.92,1}
        or {0.24,0.24,0.22,1},
      ox,oy,sc,"center",25)
  end

  return ox,oy,sc
end

function GoldCompat.summaryEvolutionRows(summary)
  local mon=summary and summary.mon
  local def=summary and summary.pokemon and mon
      and summary.pokemon[mon.species]
  local rows={}
  if not def then return rows end

  for _,evo in ipairs(def.evolutions or {}) do
    local into=evo.into or evo.species
    local target=summary.pokemon and summary.pokemon[into]
    local targetName=tostring((target and target.name) or into or "?")
    local method=tostring(evo.method or ""):upper()
    local how

    if method=="EVOLVE_LEVEL" or method=="LEVEL" then
      how="Lv. "..tostring(evo.level or "?")
    elseif method=="EVOLVE_ITEM" or method=="ITEM" then
      local item=summary.items and summary.items[evo.item]
      how=tostring((item and item.name) or evo.item or "ITEM")
    elseif method=="EVOLVE_TRADE" or method=="TRADE" then
      if evo.item then
        local item=summary.items and summary.items[evo.item]
        how="Trade + "..tostring((item and item.name) or evo.item)
      else
        how="Trade"
      end
    elseif evo.level then
      how="Lv. "..tostring(evo.level)
    elseif evo.item then
      local item=summary.items and summary.items[evo.item]
      how=tostring((item and item.name) or evo.item)
    else
      how=(method~="" and method:gsub("^EVOLVE_","")) or "Special"
    end

    rows[#rows+1]={name=targetName,how=how}
  end
  return rows
end

function GoldCompat.drawGoldSummaryIdentity(summary,ox,oy,sc)
  local mon=summary.mon
  local def=summary.pokemon and summary.pokemon[mon.species]
  if not (mon and def) then return end

  local name=mon.nickname or mon.name or def.name or mon.species or "POKéMON"
  finalText(name,10,39,4.2,{0.07,0.07,0.07,1},ox,oy,sc,"left",47)
  finalText("Lv."..tostring(mon.level or "?"),10,46,3.0,
    {0.20,0.20,0.18,1},ox,oy,sc)

  -- Same resolved sprite-package path as Party/Pokédex.
  local G=love.graphics
  G.push("all")
  G.origin()
  pcall(GoldCompat.drawCleanResolvedPortrait,summary.game,mon,
    ox+13*sc,oy+54*sc,47*sc,39*sc,"summary")
  G.pop()

  local gender=GoldCompat.genderSymbol(mon)
  if gender then
    pcall(GoldCompat.drawGenderIcon,
      ox+53*sc,oy+42*sc,10,gender)
  end

  finalText(("#%03d"):format(tonumber(def.dex) or 0),10,96,3.0,
    {0.36,0.36,0.33,1},ox,oy,sc)

  local type1,type2=GoldCompat.summaryTypeNames(summary)
  local types=type1 or "N/A"
  if type2 and type2~=type1 then types=types.." / "..type2 end
  finalText(types,10,102,2.9,{0.12,0.12,0.11,1},
    ox,oy,sc,"left",53)

  -- Bottom metadata is intentionally a two-column row: status left,
  -- evolution right. Both headers share the same baseline.
  local status=owStatus(mon) or "OK"
  finalText("STATUS",10,110,2.25,{0.40,0.40,0.37,1},ox,oy,sc)
  finalText(status,10,116,2.85,
    status=="OK" and {0.16,0.42,0.20,1} or {0.44,0.14,0.36,1},
    ox,oy,sc)

  local evos=GoldCompat.summaryEvolutionRows(summary)
  finalText("EVOLUTION",36,110,2.15,{0.40,0.40,0.37,1},ox,oy,sc,"left",26)
  if #evos==0 then
    finalText("NONE",36,116,2.35,{0.28,0.28,0.26,1},ox,oy,sc,"left",26)
  else
    local first=evos[1]
    finalText(first.name,36,116,2.30,{0.08,0.08,0.08,1},
      ox,oy,sc,"left",26)
    finalText(first.how,36,121,2.00,{0.30,0.30,0.28,1},
      ox,oy,sc,"left",26)
    if #evos>1 then
      finalText((" +%d"):format(#evos-1),56,121,1.65,
        {0.36,0.36,0.33,1},ox,oy,sc,"right",7)
    end
  end
end

function GoldCompat.drawGoldSummaryFooter(ox,oy,sc)
  finalText("SELECT: MOVE MANAGER",9,134,2.00,
    {0.96,0.95,0.90,1},ox,oy,sc,"left",58)
  finalText("←/→ PAGE  ↑/↓ POKéMON",63,134,1.62,
    {0.74,0.74,0.70,1},ox,oy,sc,"center",60)
  local backLabel="B: BACK"
  local backSize=2.00
  local backX=151-finalTextWidth(backLabel,backSize,sc)
  finalText(backLabel,backX,134,backSize,
    {0.96,0.95,0.90,1},ox,oy,sc)
end

function GoldCompat.drawGoldSummaryInfo(summary,ox,oy,sc)
  local mon=summary.mon
  local def=summary.pokemon and summary.pokemon[mon.species]
  local dex=GoldCompat.summaryDexEntry(summary)
  local stats=mon.stats or {}

  finalText("SPECIES",79,39,2.5,{0.40,0.40,0.37,1},ox,oy,sc)
  finalText(tostring((dex and dex.kind) or "N/A"):upper(),
    79,44,3.0,{0.08,0.08,0.08,1},ox,oy,sc,"left",34)

  local pseudo={dexEntry={
    gen2Height=dex and dex.height,
    gen2Weight=dex and dex.weight,
  }}
  finalText("HT",116,39,2.5,{0.40,0.40,0.37,1},ox,oy,sc)
  finalText(DexUI.heightLabel(pseudo),126,39,2.8,
    {0.08,0.08,0.08,1},ox,oy,sc,"left",24)
  finalText("WT",116,46,2.5,{0.40,0.40,0.37,1},ox,oy,sc)
  finalText(DexUI.weightLabel(pseudo),126,46,2.8,
    {0.08,0.08,0.08,1},ox,oy,sc,"left",24)

  -- HP.
  local hpMax=math.max(1,mon.maxHp or stats.hp or 1)
  finalText("HP",79,57,2.6,{0.40,0.40,0.37,1},ox,oy,sc)
  local G=love.graphics
  G.push("all")
  G.origin()
  local hx=ox+91*sc
  local hy=oy+58*sc
  local hw=52*sc
  local hh=3.0*sc
  local ratio=math.max(0,math.min(1,(mon.hp or 0)/hpMax))
  G.setColor(0.10,0.10,0.09,1)
  roundedRect("fill",hx,hy,hw,hh,hh*0.45)
  local r,gg,b,a=hpColor(ratio)
  G.setColor(r,gg,b,a)
  roundedRect("fill",hx+0.7*sc,hy+0.7*sc,
    math.max(0,(hw-1.4*sc)*ratio),math.max(1,hh-1.4*sc),hh*0.35)
  G.pop()
  finalText(("%d/%d"):format(mon.hp or 0,hpMax),
    116,64,2.65,{0.08,0.08,0.08,1},ox,oy,sc,"right",28)

  -- EXP.
  finalText("EXP POINTS",79,74,2.45,{0.40,0.40,0.37,1},ox,oy,sc)
  finalText(tostring(mon.experience or 0),119,74,2.8,
    {0.08,0.08,0.08,1},ox,oy,sc,"right",28)
  local nextExp=summary.expToNext and summary:expToNext() or 0
  finalText("NEXT LEVEL",79,81,2.45,{0.40,0.40,0.37,1},ox,oy,sc)
  finalText(tostring(nextExp),119,81,2.8,
    {0.08,0.08,0.08,1},ox,oy,sc,"right",28)

  G.push("all")
  G.origin()
  local ex=ox+80*sc
  local ey=oy+90*sc
  local ew=67*sc
  local eh=3.0*sc
  G.setColor(0.10,0.16,0.18,1)
  roundedRect("fill",ex,ey,ew,eh,eh*0.45)
  G.setColor(0.12,0.50,0.86,1)
  roundedRect("fill",ex+0.7*sc,ey+0.7*sc,
    math.max(0,(ew-1.4*sc)*GoldCompat.summaryExpRatio(summary)),
    math.max(1,eh-1.4*sc),eh*0.35)
  G.pop()

  local held=summary.itemName and summary:itemName() or nil
  finalText("HELD ITEM",79,100,2.45,{0.40,0.40,0.37,1},ox,oy,sc)
  finalText(held or "NONE",79,106,3.0,{0.08,0.08,0.08,1},
    ox,oy,sc,"left",31)

  -- Mod-owned lifetime KO counter for this individual Pokémon.
  finalText("POKéMON FAINTED",116,100,1.80,{0.40,0.40,0.37,1},
    ox,oy,sc,"left",33)
  finalText(tostring(tonumber(mon.gen3uiFainted) or 0),126,106,3.0,
    {0.08,0.08,0.08,1},ox,oy,sc,"right",20)

  GoldCompat.drawGoldSummaryFooter(ox,oy,sc)
end

function GoldCompat.summaryCompatibleMachines(summary)
  local mon=summary and summary.mon
  local def=summary and summary.pokemon and mon
      and summary.pokemon[mon.species]
  local compatible={}
  if not def then return compatible end

  -- Gold's species definition is authoritative for TM/HM compatibility.
  -- Do not infer compatibility from move type or mutate any engine tables.
  for _,moveId in ipairs(def.tmhm or {}) do
    local md=summary.moves and summary.moves[moveId]
    compatible[#compatible+1]={
      id=moveId,
      name=tostring((md and md.name) or moveId or "---"),
      typeName=tostring((md and md.type) or "—"),
      power=md and tonumber(md.power) or nil,
      accuracy=md and tonumber(md.accuracy) or nil,
    }
  end
  table.sort(compatible,function(a,b)
    return a.name<b.name
  end)
  return compatible
end

function GoldCompat.summaryLevelUpLearnset(summary)
  local mon=summary and summary.mon
  local def=summary and summary.pokemon and mon
      and summary.pokemon[mon.species]
  local learned={}
  if not def then return learned end

  -- Gen 2's authoritative EvosAttacks data is exposed as `levelMoves`.
  -- This is the same table src/battle/gen2/Mon.lua uses for:
  --   * movesAtLevel()
  --   * pokemon.level_up learnable payloads
  --   * actual post-level move offers
  for _,entry in ipairs(def.levelMoves or {}) do
    local level=tonumber(entry and entry.level)
    local moveId=entry and entry.move
    if level and moveId then
      local md=summary.moves and summary.moves[moveId]
      learned[#learned+1]={
        level=level,
        id=moveId,
        name=tostring((md and md.name) or moveId or "---")
      }
    end
  end

  table.sort(learned,function(a,b)
    if a.level==b.level then return a.name<b.name end
    return a.level<b.level
  end)
  return learned
end

function GoldCompat.drawGoldSummaryMoves(summary,ox,oy,sc)
  -- The party screen already exposes currently learned moves, so this page
  -- is dedicated to acquisition data: compatible machines + level-up moves.
  finalText("TM / HM COMPATIBILITY",79,38,2.65,{0.40,0.40,0.37,1},ox,oy,sc)

  local machines=GoldCompat.summaryCompatibleMachines(summary)
  if #machines==0 then
    finalText("NONE",80,46,2.4,{0.34,0.34,0.31,1},ox,oy,sc)
  else
    local rows=7
    local shown=math.min(#machines,rows*2)
    for i=1,shown do
      local item=machines[i]
      local col=(i-1)>=rows and 1 or 0
      local row=(i-1)%rows
      local x=80+col*34
      local y=46+row*5.2
      finalText(item.name,x,y,2.15,{0.08,0.08,0.08,1},
        ox,oy,sc,"left",31)
    end
    if #machines>shown then
      finalText((" +%d MORE"):format(#machines-shown),115,82,1.95,
        {0.36,0.36,0.33,1},ox,oy,sc,"left",31)
    end
  end

  finalText("LEVEL-UP LEARNSET",79,87,2.65,{0.40,0.40,0.37,1},ox,oy,sc)
  local learnset=GoldCompat.summaryLevelUpLearnset(summary)
  if #learnset==0 then
    finalText("NO LEVEL-UP DATA",80,95,2.25,{0.34,0.34,0.31,1},ox,oy,sc)
  else
    -- Two columns, sorted by level, with explicit level labels.
    local rows=5
    local shown=math.min(#learnset,rows*2)
    for i=1,shown do
      local item=learnset[i]
      local col=(i-1)>=rows and 1 or 0
      local row=(i-1)%rows
      local x=80+col*34
      local y=95+row*5.5
      finalText(("Lv.%d  %s"):format(item.level,item.name),
        x,y,2.1,{0.08,0.08,0.08,1},ox,oy,sc,"left",32)
    end
    if #learnset>shown then
      finalText((" +%d MORE"):format(#learnset-shown),115,123,1.9,
        {0.36,0.36,0.33,1},ox,oy,sc,"left",31)
    end
  end

  finalText("TM/HM: BAG TO TEACH",79,128,1.95,
    {0.30,0.30,0.28,1},ox,oy,sc)
  GoldCompat.drawGoldSummaryFooter(ox,oy,sc)
end

function GoldCompat.drawGoldSummaryStats(summary,ox,oy,sc)
  local mon=summary.mon
  local stats=mon.stats or {}

  finalText("TRAINER",79,39,2.5,{0.40,0.40,0.37,1},ox,oy,sc)
  finalText("OT",79,46,2.4,{0.34,0.34,0.31,1},ox,oy,sc)
  finalText(summary.otName and summary:otName() or "—",
    94,46,2.8,{0.08,0.08,0.08,1},ox,oy,sc,"left",52)
  finalText("ID",79,52,2.4,{0.34,0.34,0.31,1},ox,oy,sc)
  finalText(("%05d"):format(summary.otId and summary:otId() or 0),
    94,52,2.8,{0.08,0.08,0.08,1},ox,oy,sc)

  finalText("BATTLE STATS",79,62,2.6,{0.40,0.40,0.37,1},ox,oy,sc)

  local rows={
    {"HP",stats.hp or mon.maxHp or 0},
    {"ATTACK",stats.attack or 0},
    {"DEFENSE",stats.defense or 0},
    {"SP. ATK",stats.specialAttack or stats.special or 0},
    {"SP. DEF",stats.specialDefense or stats.special or 0},
    {"SPEED",stats.speed or 0},
  }

  for i,row in ipairs(rows) do
    local y=69+(i-1)*8.1
    finalText(row[1],81,y,2.6,{0.30,0.30,0.28,1},ox,oy,sc)
    finalText(tostring(row[2]),126,y,3.0,{0.08,0.08,0.08,1},
      ox,oy,sc,"right",20)
  end

  GoldCompat.drawGoldSummaryFooter(ox,oy,sc)
end

-- FOUND (v2.1.31): the v2.1.30 START-triggered learnset picker built here
-- was reported completely non-functional in play ("the move manager does
-- not work at all still"). Rather than continue guessing blind at a second
-- from-scratch design, the user supplied a sibling mod (Colosseum Inspired
-- UI Overhaul, a UI reskin built on the same Gen1Recomp engine and sharing
-- large parts of this file's own architecture -- same GoldCompat namespace,
-- same partySlotPanel/finalText/roundedRect helpers) with a Move Manager
-- confirmed working on BOTH generations. Reading its implementation
-- directly (rather than re-deriving one) turned up the actual reason mine
-- never worked reliably: it depended on native's own moveDetail/swapFrom
-- reorder state machine as a base layer with a picker bolted on top via a
-- borrowed button, whereas the reference design REPLACES that state machine
-- outright with its own -- one flow, triggered the exact same way the
-- pre-existing reorder screen already was, with no separate button to
-- discover at all: highlight a move (phase="current"), press A to manage
-- it, then choose either DELETE (always the first row) or any relearnable
-- move (phase="history") and press A again to apply. This port keeps that
-- proven mechanism, reskinned into this mod's own cream-panel MOVE MANAGER
-- layout (kept intact from the pre-v2.1.30 reorder screen below) rather
-- than the reference's own dark "Colosseum" visual theme, per this
-- project's standing rule that a ported feature gets its own presentation,
-- not Colosseum's.
--
-- The learnable-move pool combines TWO real sources, exactly like the
-- reference: the species' own level-up learnset (walked back through every
-- pre-evolution too, so an evolved mon can still relearn an early-stage
-- move) filtered to the mon's current level, PLUS a per-mon history of
-- every move this manager has ever seen on it (recorded the moment it's
-- first opened, and again whenever a move is deleted or replaced) so a
-- TM/tutor move forgotten through this same manager stays available to
-- relearn later -- something level-up data alone could never reconstruct,
-- confirmed by this project's own earlier research that neither game's
-- engine keeps that history natively. Field names are read defensively for
-- BOTH real schemas at once (verified against src/mods/Schemas.lua): Gen 1's
-- R.pokemon carries level1Moves+learnset and evolutions keyed by `species`,
-- Gen 2's gen2Fields carries levelMoves (which already includes level-1
-- moves) and evolutions keyed by `into` -- gen3ui's own pre-existing
-- GoldCompat.summaryLevelUpLearnset only ever read the Gen 2 shape, which
-- would have silently returned nothing at all for Gen 1.
function GoldCompat.moveManagerMoveId(entry)
  if type(entry)=="table" then
    return entry.id or entry.move or entry.moveId
  end
  return entry
end

function GoldCompat.moveManagerMoveDef(summary,entry)
  local id=GoldCompat.moveManagerMoveId(entry)
  if not id then return nil end
  local game=summary and summary.game
  local moves=(summary and summary.moves)
    or (game and game.data and game.data.moves)
  return moves and moves[id] or nil
end

function GoldCompat.moveManagerMoveName(summary,entry)
  local id=GoldCompat.moveManagerMoveId(entry)
  local def=GoldCompat.moveManagerMoveDef(summary,entry)
  return tostring((def and def.name) or id or "---")
end

function GoldCompat.moveManagerRememberId(mon,id)
  if not (type(mon)=="table" and id) then return end
  mon.__gen3uiMoveHistory=mon.__gen3uiMoveHistory or {}
  for _,known in ipairs(mon.__gen3uiMoveHistory) do
    if known==id then return end
  end
  mon.__gen3uiMoveHistory[#mon.__gen3uiMoveHistory+1]=id
end

function GoldCompat.moveManagerLearnablePool(summary)
  local mon=summary and summary.mon
  if not mon then return {} end
  local game=summary.game
  local defs=(summary.pokemon) or (game and game.data and game.data.pokemon) or {}
  local level=math.max(1,tonumber(mon.level) or 1)
  local current={}
  for _,mv in ipairs(mon.moves or {}) do
    local id=GoldCompat.moveManagerMoveId(mv)
    if id then current[id]=true end
  end

  local rows,byId={},{}
  local function add(id,learnLevel,recorded)
    if not id or current[id] or byId[id] then return end
    local row={id=id,level=tonumber(learnLevel),recorded=recorded==true}
    row.name=GoldCompat.moveManagerMoveName(summary,id)
    rows[#rows+1]=row
    byId[id]=row
  end

  -- Walk the current species plus every direct/recursive pre-evolution, so
  -- an evolved Pokémon can still relearn a move it could only have learned
  -- at an earlier stage.
  local visited={}
  local function collect(species)
    if not species or visited[species] then return end
    visited[species]=true
    for candidateId,candidate in pairs(defs) do
      if type(candidate)=="table" then
        for _,evo in ipairs(candidate.evolutions or {}) do
          local into=evo and (evo.into or evo.species)
          if into==species then collect(candidateId) end
        end
      end
    end
    local def=defs[species]
    if type(def)~="table" then return end
    for _,id in ipairs(def.level1Moves or {}) do add(id,1,false) end
    for _,entry in ipairs(def.learnset or {}) do
      local at=tonumber(entry and entry.level) or 1
      if at<=level then add(entry and entry.move,at,false) end
    end
    for _,entry in ipairs(def.levelMoves or {}) do
      local at=tonumber(entry and entry.level) or 1
      if at<=level then add(entry and entry.move,at,false) end
    end
  end
  collect(mon.species)

  for _,id in ipairs(mon.__gen3uiMoveHistory or {}) do
    add(id,nil,true)
  end

  table.sort(rows,function(a,b)
    if a.recorded~=b.recorded then return a.recorded end
    local al,bl=a.level or 999,b.level or 999
    if al~=bl then return al<bl end
    return a.name<b.name
  end)
  return rows
end

function GoldCompat.openMoveManager(summary)
  local mon=summary and summary.mon
  if not mon or mon.isEgg then return false end
  mon.moves=mon.moves or {}
  for _,mv in ipairs(mon.moves) do
    GoldCompat.moveManagerRememberId(mon,GoldCompat.moveManagerMoveId(mv))
  end
  local count=#mon.moves
  local index=math.max(1,math.min(count>0 and count or 1,
    tonumber(summary.moveIndex) or 1))
  summary.__gen3uiMoveManager={
    phase="current",
    currentIndex=index,
    targetSlot=nil,
    historyIndex=1,
    historyScroll=0,
    message=nil,
  }
  summary.moveIndex=index
  return true
end

local function moveManagerNewMoveEntry(summary,id)
  local def=GoldCompat.moveManagerMoveDef(summary,id)
  local pp=math.max(0,tonumber(def and def.pp) or 0)
  local entry={id=id,pp=pp,ppUps=0}
  if GoldCompat.generation=="gen2" or (summary and summary.pokemon) then
    entry.maxPp=pp
  end
  return entry
end

local function moveManagerMaxPp(summary,mv)
  if not mv then return 0 end
  local def=GoldCompat.moveManagerMoveDef(summary,mv)
  if type(mv)=="table" and mv.maxPp then return mv.maxPp end
  if type(mv)=="table" and mv.maxPP then return mv.maxPP end
  local base=tonumber(def and def.pp) or 0
  local ups=(type(mv)=="table" and tonumber(mv.ppUps)) or 0
  return base+ups*math.floor(base/5)
end

local function moveManagerHistoryVisible(manager,total,visible)
  manager.historyIndex=math.max(1,math.min(total,manager.historyIndex or 1))
  local scroll=math.max(0,tonumber(manager.historyScroll) or 0)
  if manager.historyIndex<=scroll then
    scroll=manager.historyIndex-1
  elseif manager.historyIndex>scroll+visible then
    scroll=manager.historyIndex-visible
  end
  manager.historyScroll=math.max(0,math.min(scroll,math.max(0,total-visible)))
end

function GoldCompat.updateMoveManager(summary,input)
  local manager=summary and summary.__gen3uiMoveManager
  local mon=summary and summary.mon
  if not (manager and mon and input) then return end
  local moves=mon.moves or {}

  if manager.phase=="current" then
    local count=#moves
    if input:wasPressed("b") then
      summary.__gen3uiMoveManager=nil
      -- Gen 2's native moveDetail/swapFrom fields (set as a side effect of
      -- forcing GREEN_PAGE open in the SELECT hook, or by the party
      -- submenu's own "MOVES" row) are never cleared by native code once
      -- this manager takes over -- left alone, both the SummaryMenu.update
      -- wrap and drawGoldSummary's fallback see moveDetail still true next
      -- frame and reopen this same manager immediately, so B never actually
      -- closed anything from the player's point of view. Harmless to clear
      -- unconditionally on Gen 1 too (it has no such fields).
      summary.moveDetail=false
      summary.moveScreen=false
      summary.swapFrom=nil
      return
    end
    if count<1 then
      manager.message="NO CURRENT MOVE TO MANAGE"
      return
    end
    if input:wasPressed("up") then
      manager.currentIndex=manager.currentIndex>1 and manager.currentIndex-1 or count
    elseif input:wasPressed("down") then
      manager.currentIndex=manager.currentIndex<count and manager.currentIndex+1 or 1
    elseif input:wasPressed("a") then
      manager.targetSlot=manager.currentIndex
      manager.phase="history"
      manager.historyIndex=1
      manager.historyScroll=0
      manager.message=nil
    end
    summary.moveIndex=manager.currentIndex
    return
  end

  local pool=GoldCompat.moveManagerLearnablePool(summary)
  local total=#pool+1 -- row 1 is always DELETE MOVE
  moveManagerHistoryVisible(manager,total,5)

  if input:wasPressed("b") then
    manager.phase="current"
    manager.targetSlot=nil
    manager.message=nil
    return
  elseif input:wasPressed("up") then
    manager.historyIndex=manager.historyIndex>1 and manager.historyIndex-1 or total
    moveManagerHistoryVisible(manager,total,5)
    return
  elseif input:wasPressed("down") then
    manager.historyIndex=manager.historyIndex<total and manager.historyIndex+1 or 1
    moveManagerHistoryVisible(manager,total,5)
    return
  elseif not input:wasPressed("a") then
    return
  end

  local slot=math.max(1,math.min(#moves,tonumber(manager.targetSlot) or 1))
  local old=moves[slot]
  if not old then
    manager.phase="current"
    manager.message="MOVE SLOT IS EMPTY"
    return
  end

  if manager.historyIndex==1 then
    if #moves<=1 then
      manager.message="THE LAST MOVE CAN'T BE DELETED"
      return
    end
    local oldId=GoldCompat.moveManagerMoveId(old)
    local oldName=GoldCompat.moveManagerMoveName(summary,old)
    GoldCompat.moveManagerRememberId(mon,oldId)
    table.remove(moves,slot)
    manager.currentIndex=math.max(1,math.min(slot,#moves))
    summary.moveIndex=manager.currentIndex
    manager.phase="current"
    manager.targetSlot=nil
    manager.message="DELETED "..oldName
    return
  end

  local choice=pool[manager.historyIndex-1]
  if not choice then return end
  local oldId=GoldCompat.moveManagerMoveId(old)
  GoldCompat.moveManagerRememberId(mon,oldId)
  GoldCompat.moveManagerRememberId(mon,choice.id)
  moves[slot]=moveManagerNewMoveEntry(summary,choice.id)
  manager.currentIndex=slot
  summary.moveIndex=slot
  manager.phase="current"
  manager.targetSlot=nil
  manager.message="LEARNED "..choice.name

  -- Same event Mon.lua's own Mon.learnMove raises for every other new-move
  -- grant on Gen 2 (level-up/TM/evolution); Gen 1 has no equivalent single
  -- choke point to match, so this is offered unconditionally for any mod
  -- that hooks the event on either generation.
  pcall(function()
    require("src.mods.Runtime").emit("pokemon.move_learned",
      {mon=mon,moveId=choice.id})
  end)
  if summary.playSwapSfx then pcall(summary.playSwapSfx,summary) end
end

function GoldCompat.drawGoldMoveManager(summary)
  local mon=summary.mon
  if not mon then return end
  local manager=summary.__gen3uiMoveManager
  if not manager then return end

  local ox,oy,sc=safeFullCanvas()
  local G=love.graphics
  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)

  G.setColor(0.94,0.93,0.87,1)
  G.rectangle("fill",0,0,160,144)
  G.setColor(0.08,0.08,0.08,1)
  G.rectangle("fill",4,4,152,17)
  G.setColor(0.99,0.985,0.955,1)
  G.rectangle("fill",5,5,150,15)

  -- Soft shadow + cream face + a thin warm outline, instead of the old
  -- thick near-black double-rounded-rect frame this screen inherited
  -- unchanged from v2.1.30's reorder-only Move Manager. That frame reads as
  -- a stark black box at this canvas's render scale -- the exact same class
  -- of "black border" complaint already fixed for partySlotPanel back in
  -- v2.1.30, just never applied to this screen's own card chrome until now.
  G.setColor(0.10,0.10,0.09,0.30)
  roundedRect("fill",8,28,72,101,3)
  roundedRect("fill",83,28,71,101,3)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",7,27,72,101,3)
  roundedRect("fill",82,27,71,101,3)
  G.setColor(0.32,0.30,0.25,0.85)
  roundedRect("line",7,27,72,101,3)
  roundedRect("line",82,27,71,101,3)
  G.setColor(0.08,0.08,0.07,1)
  G.rectangle("fill",4,132,152,8)
  G.pop()

  finalText("MOVE MANAGER",9,8,4.8,{0.06,0.06,0.06,1},ox,oy,sc)

  local moves=mon.moves or {}
  for i=1,4 do
    local mv=moves[i]
    local md=GoldCompat.summaryMoveDef(summary,mv)
    local y=35+(i-1)*20
    local selected=manager.phase=="current" and i==(manager.currentIndex or 1)
    local target=manager.phase=="history" and i==manager.targetSlot

    G.push("all")
    G.translate(ox,oy)
    G.scale(sc,sc)
    if selected then
      G.setColor(0.11,0.28,0.38,1)
      roundedRect("fill",12,y-1,61,17,2)
    elseif target then
      G.setColor(0.74,0.59,0.20,1)
      roundedRect("fill",12,y-1,61,17,2)
    end
    G.pop()

    finalText(GoldCompat.summaryMoveName(summary,mv),
      16,y+2,3.15,
      (selected or target) and {0.98,0.97,0.92,1} or {0.08,0.08,0.08,1},
      ox,oy,sc,"left",38)

    if mv then
      local pp=type(mv)=="table" and (mv.pp or "?") or "?"
      local maxpp=moveManagerMaxPp(summary,mv)
      if maxpp<=0 then maxpp=(md and md.pp) or pp end
      finalText(("PP %s/%s"):format(pp,maxpp),53,y+8,2.2,
        (selected or target) and {0.90,0.91,0.87,1} or {0.32,0.32,0.29,1},
        ox,oy,sc,"right",18)
    end
  end

  if manager.phase=="current" then
    finalText("MOVE DATA",88,35,2.7,{0.40,0.40,0.37,1},ox,oy,sc)
    local current=moves[manager.currentIndex or 1]
    local def=GoldCompat.summaryMoveDef(summary,current)
    if def then
      finalText(tostring(def.type or "—"),88,43,3.0,
        {0.08,0.08,0.08,1},ox,oy,sc)
      finalText("POWER",88,53,2.4,{0.34,0.34,0.31,1},ox,oy,sc)
      finalText((tonumber(def.power) or 0)>1 and tostring(def.power) or "—",
        126,53,2.8,{0.08,0.08,0.08,1},ox,oy,sc,"right",18)
      finalText("ACCURACY",88,61,2.4,{0.34,0.34,0.31,1},ox,oy,sc)
      finalText((tonumber(def.accuracy) or 0)>0 and tostring(def.accuracy) or "—",
        126,61,2.8,{0.08,0.08,0.08,1},ox,oy,sc,"right",18)

      finalText("DESCRIPTION",88,73,2.4,{0.40,0.40,0.37,1},ox,oy,sc)
      local clean=GoldCompat.cleanWrappedText(def.description or "")
      local f=font(2.55*UI_TEXT_SCALE)
      local _,wrapped=f:getWrap(clean,58)
      for i=1,math.min(5,#wrapped) do
        finalText(wrapped[i],88,80+(i-1)*7,2.55,
          {0.10,0.10,0.09,1},ox,oy,sc,"left",58)
      end
    else
      finalText("NO MOVE",88,45,3.0,{0.34,0.34,0.31,1},ox,oy,sc)
    end
    finalText("A:MANAGE  B:BACK",9,134,2.35,{0.96,0.95,0.90,1},ox,oy,sc)
  else
    local pool=GoldCompat.moveManagerLearnablePool(summary)
    local total=#pool+1
    moveManagerHistoryVisible(manager,total,5)

    finalText("REPLACE WITH",88,35,2.7,{0.40,0.40,0.37,1},ox,oy,sc)
    local first=(manager.historyScroll or 0)+1
    for row=1,5 do
      local index=first+row-1
      if index>total then break end
      local y=44+(row-1)*15.5
      local selected=index==manager.historyIndex

      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      if selected then
        G.setColor(0.11,0.28,0.38,1)
        roundedRect("fill",85,y-2,65,15,2)
      end
      G.pop()

      if index==1 then
        finalText("DELETE MOVE",89,y,2.5,
          selected and {0.98,0.97,0.92,1} or {0.55,0.16,0.14,1},
          ox,oy,sc,"left",58)
        finalText("no replacement",89,y+7,1.9,
          selected and {0.90,0.91,0.87,1} or {0.40,0.40,0.37,1},
          ox,oy,sc,"left",58)
      else
        local entry=pool[index-1]
        local badge=entry.recorded and "PAST" or ("Lv."..tostring(entry.level or "--"))
        finalText(entry.name,89,y,2.5,
          selected and {0.98,0.97,0.92,1} or {0.08,0.08,0.08,1},
          ox,oy,sc,"left",58)
        finalText(badge,89,y+7,1.9,
          selected and {0.90,0.91,0.87,1} or {0.34,0.34,0.31,1},
          ox,oy,sc,"left",58)
      end
    end
    if total==0 then
      finalText("NOTHING TO LEARN YET",88,45,2.2,{0.34,0.34,0.31,1},ox,oy,sc)
    end
    finalText("A:APPLY  B:BACK",9,134,2.35,{0.96,0.95,0.90,1},ox,oy,sc)
  end

  if manager.message then
    finalText(manager.message,9,124,2.0,{0.16,0.42,0.20,1},ox,oy,sc,"left",140)
  end
end

function GoldCompat.drawGoldSummary(summary,winW,winH)
  if not (summary and summary.mon) then return end

  -- Eggs keep their purpose-built native Gold summary screen; revealing the
  -- hidden species/stats would violate Gold's own egg flow.
  if summary.mon.isEgg then
    local Summary=GoldCompat.requiredEngineModule("src.ui.gen2.SummaryMenu")
    if Summary.__gen3uiOriginalDrawWidescreen then
      return Summary.__gen3uiOriginalDrawWidescreen(summary,winW,winH)
    end
  end

  if summary.__gen3uiMoveManager then
    return GoldCompat.drawGoldMoveManager(summary)
  end
  if summary.moveDetail or summary.moveScreen then
    -- Reached via the party field-submenu's native "MOVES" row rather than
    -- the SELECT hook below; open the same manager instead of falling
    -- through to native's own reorder-only presentation.
    if GoldCompat.openMoveManager(summary) then
      return GoldCompat.drawGoldMoveManager(summary)
    end
  end

  local title=(summary.page==1 and "POKéMON INFO")
      or (summary.page==2 and "POKéMON MOVES")
      or "POKéMON STATS"

  local ox,oy,sc=GoldCompat.drawGoldSummaryBase(summary,title)
  GoldCompat.drawGoldSummaryIdentity(summary,ox,oy,sc)

  if summary.page==2 then
    GoldCompat.drawGoldSummaryMoves(summary,ox,oy,sc)
  elseif summary.page==3 then
    GoldCompat.drawGoldSummaryStats(summary,ox,oy,sc)
  else
    GoldCompat.drawGoldSummaryInfo(summary,ox,oy,sc)
  end
end


function GoldCompat.panelText(text,x,y,size,color,align,width)
  local ox,oy,sc=finalCanvas()
  return finalText(tostring(text or ""),x,y,size,color,ox,oy,sc,align,width)
end

-- Resolve the move a TM/HM item teaches without assuming which field a
-- native row/entry table uses for the item's id. gen1's own categorized Bag
-- adapter (gen1BagGoldAdapter) always uses row.value, but the REAL native
-- Gen 2 PackMenu/MartMenu row/entry tables are the engine's own, unknown
-- from this mod's source alone -- so every plausible field is tried, and
-- TM/HM ids are conventionally identical to their own display name (TM31,
-- HM01, ...) in these data tables, which is tried last as a safe fallback.
-- Returns nil (no lookup, no crash) the moment nothing matches.
--
-- FOUND (v2.1.27): this never actually worked for Gen 2 -- confirmed by
-- reading the real `src/import/RomExtractorGen2.lua:4428` extractor and
-- `src/ui/gen2/MartMenu.lua:902` (`if def and def.teaches then ...`): a Gen 2
-- item's move field is `def.teaches` (a plain move-id STRING) directly on
-- the item definition. Gen 1's shape (`def.machine={kind=,number=,move=}`,
-- confirmed at `src/import/RomExtractor.lua:884/896`) is a Gen 1-only shape
-- that never existed for Gen 2 items at all -- so this lookup, written and
-- verified only against Gen 1's item data, silently returned nil for every
-- single Gen 2 item it was ever asked about. Both real shapes are now tried.
local function goldMachineMoveName(game,row)
  -- `game` may not have been passed in directly (native Gold PackMenu/MartMenu
  -- instances don't necessarily expose their own `.game` field -- that was an
  -- unverified guess). GoldCompat.mod.game is the same live game-data handle
  -- used elsewhere in this file (see GoldCompat.installBattlePredicateGuard/
  -- installBattleUiFirewall) and is always populated once the mod is
  -- installed, so it's tried as the reliable fallback source.
  game=game or (GoldCompat.mod and GoldCompat.mod.game)
  if not (game and game.data and row) then return nil end
  local items=game.data.items
  local moves=game.data.moves
  if not (items and moves) then return nil end

  local function resolve(cand)
    if type(cand)~="string" then return nil end
    local ok,def=pcall(function() return items[cand] end)
    if not (ok and type(def)=="table") then return nil end
    -- Gen 2's real shape: def.teaches is the move id directly.
    local moveId=def.teaches
    -- Gen 1's real shape: def.machine.move is the move id.
    if not moveId and def.machine then moveId=def.machine.move end
    if not moveId then return nil end
    local ok2,move=pcall(function() return moves[moveId] end)
    if ok2 and type(move)=="table" and move.name then
      return move.name
    end
    return moveId
  end

  -- Try the plausible id-field names first (fast path)...
  local candidates={row.id,row.value,row.item,row.key,row.name}
  for _,cand in ipairs(candidates) do
    local name=resolve(cand)
    if name then return name end
  end

  -- ...then, since the real native row/entry shape is unknown, fall back to
  -- trying EVERY string-valued field on the row as a candidate item id. This
  -- makes the lookup independent of guessing the correct field name: as long
  -- as some field on the row holds the item's id string, this finds it.
  for k,v in pairs(row) do
    if type(v)=="string" and k~="teaches" then
      local name=resolve(v)
      if name then return name end
    end
  end

  return nil
end

function GoldCompat.drawGoldPack(pack,winW,winH,embedded)
  local G=love.graphics
  winW=winW or G.getWidth()
  winH=winH or G.getHeight()
  local ox,oy,sc=finalCanvas()

  -- Hanging field PACK: never paint the whole screen.  The live overworld
  -- remains visible beneath this panel because PackMenu is patched non-opaque.
  -- Enlarged so the panel uses most of the viewport width while keeping a top
  -- strip clear for overlays such as the DV reader.
  local x=embedded and 5 or 8
  local y=embedded and 24 or 16
  local w=embedded and 150 or 144
  local h=embedded and 112 or 120

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)

  G.setColor(0.05,0.05,0.05,0.36)
  roundedRect("fill",x+2,y+2,w,h,4)
  G.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",x,y,w,h,4)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+2,y+2,w-4,h-4,3)
  drawUnifiedBorder(x,y,w,h,1)

  local pocket=pack.pocket and pack:pocket() or {id="ITEM",label="ITEMS"}
  local tabs={"ITEMS","BALLS","KEY","TM/HM"}
  local ids={"ITEM","BALL","KEY_ITEM","TM_HM"}
  local tabW=(w-8)/4
  for i,label in ipairs(tabs) do
    local tx=x+4+(i-1)*tabW
    local selected=pocket.id==ids[i]
    G.setColor(selected and 0.11 or 0.86,
               selected and 0.28 or 0.84,
               selected and 0.38 or 0.77,1)
    roundedRect("fill",tx,y+5,tabW-1,10,1.5)
  end

  -- List body.
  G.setColor(0.84,0.82,0.72,1)
  G.rectangle("fill",x+5,y+18,w-10,1)

  local rows=pack.rows or {}

  -- Gen 1's categorized Bag (gen1BagGoldAdapter) already annotates its own
  -- synthetic rows with .teaches/.showCount=false for every TM/HM, so BOTH
  -- generations' TM/HM rows show the move they teach here.
  --
  -- FOUND (v2.1.27): the previous assumption behind this block was wrong on
  -- two counts, confirmed by reading the real `src/ui/gen2/PackMenu.lua:292`
  -- (`rebuild()`). First, native Gen 2 rows are NEVER missing `.teaches` --
  -- `rebuild()` sets `row.teaches=self:moveLabel(def and def.teaches)` for
  -- EVERY row in the TM_HM pocket, TMs included, so the `row.teaches==nil`
  -- guard below never ran the enrichment for a real native row at all (it
  -- only ever helped a hand-built row lacking a native `.teaches`, if one
  -- ever reaches this path). Second, and this is what actually hid TM move
  -- names: native ALSO sets `row.showCount=true` for a TM row on purpose
  -- (`pocket=="TM_HM" and itemId doesn't start with "HM_"`, since a TM prints
  -- its own ×NN stack count in the real games) -- and the DRAW code below
  -- was an if/elseif that only ever showed `teaches` when `showCount` was
  -- false. Every TM row already had a correct move name sitting in
  -- `row.teaches`, but could never reach the screen because `showCount`
  -- being true (correctly, by design) always won the branch. HM rows never
  -- exposed this because native sets `showCount=false` for HMs, so a
  -- (working by accident) `elseif` happened to fall through to `teaches`.
  -- Also separately fixed: `goldMachineMoveName` itself only ever checked
  -- Gen 1's `def.machine.move` shape, never Gen 2's real `def.teaches`
  -- shape (see that function's own updated comment) -- so the Mart BUY
  -- list's TM/HM move-name append and this enrichment fallback were both
  -- silently dead for Gen 2 regardless of this showCount bug.
  --
  -- Fixed here by forcing `showCount=false` for any TM_HM-pocket row that
  -- already has (or was just given) a `teaches` value, matching Gen 1's own
  -- adapter's explicit choice to always show the move over the count for a
  -- TM/HM row -- consistent with keeping Gen 1/Gen 2 presentation identical
  -- per the user's own repeated parity requests.
  local packGame=pack.game or (GoldCompat.mod and GoldCompat.mod.game)
  local isTmHmPocket=(pocket.id=="TM_HM")
  for _,row in ipairs(rows) do
    if type(row)=="table" then
      if row.teaches==nil and packGame then
        local moveName=goldMachineMoveName(packGame,row)
        if moveName then row.teaches=moveName end
      end
      if isTmHmPocket and row.teaches then
        row.showCount=false
      end
    end
  end

  -- Row pitch and the selection highlight's height are both derived from
  -- the label font's REAL measured glyph height (see bagPackRowHeight),
  -- not a constant sized for the default TEXT SIZE. At larger TEXT SIZE /
  -- bold TEXT THICKNESS settings the real glyph box is taller than a fixed
  -- 9-10px band, so the old fixed height let text spill out of (and look
  -- misaligned against) its own highlight, not just into the row below.
  local rowH=GoldCompat.bagPackRowHeight()
  local highlightH=rowH-1
  local listTop=y+23
  local visible=tonumber(pack.visibleRows)
      or GoldCompat.bagPackVisibleRows(embedded)

  -- FOUND: `first` used to be read straight off the native pack.scroll field
  -- (first=(pack.scroll or 0)+1) with no clamping of its own. Every other
  -- restyled list in this file (PC withdraw/toss, Box list, etc.) derives its
  -- own scroll window directly from the selected index and its own visible
  -- row count instead of trusting a native scroll field -- for good reason:
  -- pack.scroll is paced by whatever row count Gen1Recomp's OWN native Pack
  -- Menu list assumes, which has no reason to match GoldCompat.bagPackVisibleRows
  -- (ours can be smaller, e.g. 4 rows at larger TEXT SIZE settings, or simply
  -- different by design). Once the selected row advanced further than native's
  -- scroll had paced for OUR narrower window, pack.index fell outside every
  -- r=1..visible slot actually drawn below -- so idx never equaled pack.index
  -- for any drawn row, and the highlight (and everything else keyed off
  -- `selected`) simply stopped appearing for the rest of the list. Native
  -- scroll is still used as a starting hint (so normal single-step scrolling
  -- still feels native), but is now clamped so the selected row is always
  -- inside the window we actually draw, regardless of how native paced it.
  local totalForScroll=#rows+1 -- +1 for the CANCEL row, selectable like any other
  local selectedIdx=pack.index or 1
  local first=(pack.scroll or 0)+1
  if selectedIdx<first then
    first=selectedIdx
  elseif selectedIdx>first+visible-1 then
    first=selectedIdx-visible+1
  end
  first=math.max(1,math.min(first,math.max(1,totalForScroll-visible+1)))

  for r=1,visible do
    local idx=first+r-1
    local yy=listTop+(r-1)*rowH
    local row=rows[idx]
    local isCancel=(idx>#rows and idx==(pack.index or 1))
    local selected=idx==(pack.index or 1)

    if selected then
      G.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",x+6,yy-1,w-12,highlightH,1.5)
    end

    if row then
      local label=tostring(row.name or row.id or "")
      G.setColor(selected and 1 or 0.06,selected and 1 or 0.06,
                 selected and 1 or 0.06,1)
      -- native final text is drawn outside transform below
    elseif idx==#rows+1 then
      -- CANCEL row
    end
  end

  -- Description / message strip.
  G.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",x+5,y+h-29,w-10,22,2)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+7,y+h-27,w-14,18,1.5)

  G.pop()

  for i,label in ipairs(tabs) do
    local tx=x+4+(i-1)*tabW
    GoldCompat.panelText(label,tx,y+7,3.0,
      pocket.id==ids[i] and {0.98,0.97,0.92,1} or {0.22,0.22,0.20,1},
      "center",tabW-1)
  end

  -- Scroll indicators reflect the same authoritative viewport as the list --
  -- `first` (clamped above), not the raw native pack.scroll, so these always
  -- agree with what is actually drawn.
  if first>1 then
    GoldCompat.panelText("▲",x+w-11,y+20,2.1,{0.30,0.30,0.27,1})
  end
  if (first+visible-1)<totalForScroll then
    GoldCompat.panelText("▼",x+w-11,y+h-34,2.1,{0.30,0.30,0.27,1})
  end

  for r=1,visible do
    local idx=first+r-1
    local yy=listTop+(r-1)*rowH
    local row=rows[idx]
    local selected=idx==(pack.index or 1)
    if row then
      local label=tostring(row.name or row.id or "")
      GoldCompat.panelText(label,x+9,yy+1,4.5,
        selected and {1,1,1,1} or {0.06,0.06,0.06,1},"left",w-27)
      if row.showCount then
        GoldCompat.panelText("×"..tostring(row.count or 1),x+w-20,yy+1,3.5,
          selected and {1,1,1,1} or {0.28,0.28,0.25,1},"right",12)
      elseif row.teaches then
        GoldCompat.panelText(row.teaches,x+w-31,yy+1,3.0,
          selected and {0.90,0.90,0.86,1} or {0.34,0.34,0.31,1},"right",24)
      end
    elseif idx==#rows+1 then
      GoldCompat.panelText("CANCEL",x+9,yy+1,4.5,
        selected and {1,1,1,1} or {0.06,0.06,0.06,1})
    end
  end

  local desc
  if pack.message then
    desc=table.concat(pack.message," ")
  elseif pack.description then
    local ok,v=pcall(pack.description,pack)
    if ok then desc=v end
  end
  desc=tostring(desc or "Choose an item."):gsub("<NEXT>"," "):gsub("%s+"," ")
  local f=font(3.5*UI_TEXT_SCALE)
  local _,wrapped=f:getWrap(desc,w-18)
  for i=1,math.min(2,#wrapped) do
    GoldCompat.panelText(wrapped[i],x+10,y+h-24+(i-1)*7,3.5,
      {0.07,0.07,0.07,1},"left",w-20)
  end

  -- Native Pack subflows visualized without touching their input.
  if pack.submenu then
    local m=pack.submenu
    local count=#(m.rows or {})
    local mw=34
    local mh=count*9+8
    local mx=x+5
    local my=math.max(y+20,y+h-mh-32)
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.08,0.08,0.07,1); roundedRect("fill",mx,my,mw,mh,2)
    G.setColor(0.99,0.985,0.95,1); roundedRect("fill",mx+2,my+2,mw-4,mh-4,1.5)
    for i=1,count do
      if i==m.index then
        G.setColor(0.10,0.10,0.09,1)
        roundedRect("fill",mx+4,my+4+(i-1)*9,mw-8,8,1)
      end
    end
    G.pop()
    for i,id in ipairs(m.rows or {}) do
      local labels={use="USE",give="GIVE",toss="TOSS",sel="SEL",quit="QUIT"}
      GoldCompat.panelText(labels[id] or tostring(id),mx+8,my+5+(i-1)*9,2.7,
        i==m.index and {1,1,1,1} or {0.06,0.06,0.06,1})
    end
  end

  if pack.qtyState then
    local q=pack.qtyState
    GoldCompat.panelText(("HOW MANY?  ×%02d"):format(q.qty or 1),
      x+10,y+h-41,2.9,{0.10,0.10,0.09,1})
  end
  if pack.confirm then
    GoldCompat.panelText(pack.confirm.choice==1 and "YES  /  no" or "yes  /  NO",
      x+w-40,y+h-41,2.6,{0.10,0.10,0.09,1})
  end
end

function GoldCompat.drawGoldMart(mart,winW,winH)
  local ox,oy,sc=finalCanvas()
  local G=love.graphics
  local hanging=(mart.phase=="top" or mart.phase=="outro"
    or mart.phase=="intro")

  if not hanging then
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.94,0.93,0.87,1); G.rectangle("fill",0,0,160,144)
    G.setColor(0.08,0.08,0.08,1); G.rectangle("fill",4,4,152,16)
    G.setColor(0.99,0.985,0.955,1); G.rectangle("fill",5,5,150,14)
    G.pop()

    GoldCompat.panelText("POKé MART",10,7,5.0,{0.06,0.06,0.06,1})
    GoldCompat.panelText(("¥%d"):format(mart.money and mart:money() or 0),
      121,8,4.0,{0.12,0.12,0.11,1},"right",29)
  end

  if mart.phase=="top" or mart.phase=="outro" then
    local labels={"BUY","SELL","EXIT"}
    local x,y,w,h=94,25,58,49
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    drawShopPanel(x,y,w,h,false)
    for i=1,3 do
      local yy=y+8+(i-1)*13
      if i==(mart.topIndex or 1) and mart.phase=="top" then
        G.setColor(0.10,0.10,0.09,1)
        roundedRect("fill",x+5,yy-1,w-10,10,1.5)
      end
    end
    G.pop()
    for i,label in ipairs(labels) do
      GoldCompat.panelText(label,x+12,y+9+(i-1)*13,4.0,
        i==(mart.topIndex or 1) and mart.phase=="top"
          and {1,1,1,1} or {0.06,0.06,0.06,1})
    end
  elseif mart.phase=="sell" and mart.pack then
    GoldCompat.drawGoldPack(mart.pack,winW,winH,true)
  else
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    drawShopPanel(6,25,148,79,false)
    G.pop()
    local entries=mart.entries or {}
    local first=(mart.scroll or 0)+1
    for r=1,5 do
      local idx=first+r-1
      local yy=31+(r-1)*14
      local entry=entries[idx]
      local selected=idx==(mart.index or 1)
      if entry then
        if selected then
          G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
          G.setColor(0.10,0.10,0.09,1); roundedRect("fill",11,yy-2,138,12,2)
          G.pop()
        end
        local label=entry.name or entry.id
        local moveName=goldMachineMoveName(
          mart.game or (GoldCompat.mod and GoldCompat.mod.game),entry)
        if moveName then label=tostring(label).." - "..moveName end
        GoldCompat.panelText(label,18,yy,3.9,
          selected and {1,1,1,1} or {0.07,0.07,0.07,1},"left",85)
        GoldCompat.panelText(("¥%d"):format(entry.price or 0),116,yy,3.6,
          selected and {1,1,1,1} or {0.12,0.12,0.11,1},"right",31)
      elseif idx==#entries+1 then
        GoldCompat.panelText("CANCEL",18,yy,3.9,
          selected and {1,1,1,1} or {0.07,0.07,0.07,1})
      end
    end
  end

  -- The mart's own speech/message/confirmation state remains authoritative.
  local lines=nil
  if mart.message and mart.message.pages then
    lines=mart.message.pages[mart.message.page or 1]
  elseif mart.confirm and mart.confirm.pages then
    lines=mart.confirm.pages[mart.confirm.page or 1]
  elseif mart.topLines then
    lines=mart.topLines
  elseif mart.description then
    local ok,d=pcall(mart.description,mart)
    if ok and d then lines={d} end
  end
  if lines then
    if type(lines)=="string" then lines={lines} end
    local bx,by,bw,bh=4,109,152,31
    if hanging then bx,by,bw,bh=8,108,144,29 end
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.04,0.04,0.04,hanging and 0.34 or 1)
    roundedRect("fill",bx,by,bw,bh,hanging and 3 or 0)
    G.setColor(0.99,0.985,0.95,1)
    roundedRect("fill",bx+2,by+2,bw-4,bh-4,hanging and 2 or 0)
    if hanging then drawUnifiedBorder(bx,by,bw,bh,0) end
    G.pop()
    for i,line in ipairs(lines) do
      if i<=2 then
        GoldCompat.panelText(tostring(line),bx+7,by+7+(i-1)*8,3.3,
          {0.06,0.06,0.06,1},"left",bw-14)
      end
    end
  end

  if mart.phase=="buyQuantity" or mart.phase=="sellQuantity" then
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    drawShopPanel(91,73,59,25,true)
    G.pop()
    GoldCompat.panelText(("×%02d"):format(mart.qty or 1),97,80,4.3,
      {0.06,0.06,0.06,1})
  end
  if mart.confirm and mart.confirm.page>=#(mart.confirm.pages or {}) then
    GoldCompat.panelText(mart.confirm.choice==1 and "YES   no" or "yes   NO",
      112,94,2.9,{0.08,0.08,0.08,1})
  end
end


function GoldCompat.cleanPcText(value,playerName)
  local text=tostring(value or "")
  text=text:gsub("{PLAYER}",playerName or "GOLD")
  text=text:gsub("#MON","POKéMON")
  text=text:gsub("#DEX","POKéDEX")
  text=text:gsub("<PK><MN>","POKéMON")
  return text
end

function GoldCompat.drawGoldCenterPc(pc,winW,winH)
  local ox,oy,sc=finalCanvas()
  local G=love.graphics
  local player=(pc.playerName and pc:playerName()) or "GOLD"

  -- MESSAGE / BOOT / ACCESS pages: only a hanging dialogue panel. The world
  -- remains fully visible behind it.
  if pc.message then
    local page=pc.message.pages and pc.message.pages[pc.message.page or 1] or {}
    local x,y,w,h=8,108,144,29

    G.push("all")
    G.translate(ox,oy)
    G.scale(sc,sc)
    G.setColor(0.04,0.04,0.04,0.34)
    roundedRect("fill",x+2,y+2,w,h,3)
    G.setColor(0.08,0.08,0.07,1)
    roundedRect("fill",x,y,w,h,3)
    G.setColor(0.99,0.985,0.95,1)
    roundedRect("fill",x+2,y+2,w-4,h-4,2)
    drawUnifiedBorder(x,y,w,h,0)
    G.pop()

    for i,line in ipairs(page or {}) do
      if i<=3 then
        GoldCompat.panelText(
          GoldCompat.cleanPcText(line,player),
          x+8,y+6+(i-1)*7,3.25,{0.06,0.06,0.06,1},"left",w-16)
      end
    end
    if pc.message.page and pc.message.pages
        and pc.message.page<#pc.message.pages then
      GoldCompat.panelText("▼",x+w-13,y+h-10,2.8,{0.12,0.12,0.11,1})
    end
    return
  end

  -- Whose-PC selector: same compact hanging-panel concept as Gen 1.
  local entries=pc.entries or {}
  local w=67
  local h=10+#entries*13
  local x=88
  local y=13

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  G.setColor(0.04,0.04,0.04,0.34)
  roundedRect("fill",x+2,y+2,w,h,3)
  G.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",x,y,w,h,3)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+2,y+2,w-4,h-4,2)
  drawUnifiedBorder(x,y,w,h,0)

  for i,_ in ipairs(entries) do
    local yy=y+5+(i-1)*13
    if i==(pc.index or 1) then
      G.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",x+5,yy-1,w-10,10,1.5)
    end
  end
  G.pop()

  for i,entry in ipairs(entries) do
    local yy=y+5+(i-1)*13
    local selected=i==(pc.index or 1)
    GoldCompat.panelText(
      GoldCompat.cleanPcText(entry.label,player),
      x+9,yy+1,3.25,
      selected and {1,1,1,1} or {0.06,0.06,0.06,1},
      "left",w-18)
  end

  -- Native PC question / Oak-rating yes-no uses our dialogue strip.
  local prompt=pc.confirm and pc.confirm.prompt or {"Access whose PC?"}
  local dx,dy,dw,dh=8,108,144,29
  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  G.setColor(0.04,0.04,0.04,0.34)
  roundedRect("fill",dx+2,dy+2,dw,dh,3)
  G.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",dx,dy,dw,dh,3)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",dx+2,dy+2,dw-4,dh-4,2)
  drawUnifiedBorder(dx,dy,dw,dh,0)
  G.pop()

  for i,line in ipairs(prompt or {}) do
    GoldCompat.panelText(GoldCompat.cleanPcText(line,player),
      dx+8,dy+6+(i-1)*7,3.2,{0.06,0.06,0.06,1},"left",95)
  end

  if pc.confirm then
    local c=pc.confirm.choice or 1
    G.push("all")
    G.translate(ox,oy)
    G.scale(sc,sc)
    local qx,qy,qw,qh=117,79,35,27
    G.setColor(0.08,0.08,0.07,1)
    roundedRect("fill",qx,qy,qw,qh,2)
    G.setColor(0.99,0.985,0.95,1)
    roundedRect("fill",qx+2,qy+2,qw-4,qh-4,1.5)
    if c==1 then
      G.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",qx+5,qy+5,qw-10,8,1)
    else
      G.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",qx+5,qy+15,qw-10,8,1)
    end
    G.pop()
    GoldCompat.panelText("YES",qx+10,qy+6,2.8,
      c==1 and {1,1,1,1} or {0.06,0.06,0.06,1})
    GoldCompat.panelText("NO",qx+10,qy+16,2.8,
      c==2 and {1,1,1,1} or {0.06,0.06,0.06,1})
  end
end

function GoldCompat.drawGoldPcRoot(pc)
  local ox,oy,sc=finalCanvas()
  local G=love.graphics

  if pc.message then
    local x,y,w,h=8,108,144,29
    G.push("all")
    G.translate(ox,oy)
    G.scale(sc,sc)
    G.setColor(0.04,0.04,0.04,0.34)
    roundedRect("fill",x+2,y+2,w,h,3)
    G.setColor(0.08,0.08,0.07,1)
    roundedRect("fill",x,y,w,h,3)
    G.setColor(0.99,0.985,0.95,1)
    roundedRect("fill",x+2,y+2,w-4,h-4,2)
    drawUnifiedBorder(x,y,w,h,0)
    G.pop()

    local lines=type(pc.message)=="table" and pc.message or {pc.message}
    for i,line in ipairs(lines) do
      if i<=3 then
        GoldCompat.panelText(GoldCompat.cleanPcText(line),
          x+8,y+6+(i-1)*7,3.2,{0.06,0.06,0.06,1},"left",w-16)
      end
    end
    return
  end
  G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
  G.setColor(0.94,0.93,0.87,1); G.rectangle("fill",0,0,160,144)
  G.setColor(0.08,0.08,0.08,1); G.rectangle("fill",4,4,152,16)
  G.setColor(0.99,0.985,0.955,1); G.rectangle("fill",5,5,150,14)

  partySlotPanel(5,24,69,96,true)
  partySlotPanel(79,24,76,96,false)
  G.setColor(0.08,0.08,0.07,1); G.rectangle("fill",4,127,152,13)
  G.pop()

  GoldCompat.panelText("POKéMON PC",10,7,5.0,{0.06,0.06,0.06,1})
  local save=pc.save or (pc.game and pc.game.save) or {}
  GoldCompat.panelText("STORAGE",12,31,3.0,{0.34,0.34,0.31,1})
  GoldCompat.panelText(("CURRENT BOX  %d"):format(save.currentBox or 1),
    12,40,4.0,{0.08,0.08,0.08,1})
  GoldCompat.panelText(("PARTY  %d / 6"):format(#(save.party or {})),
    12,50,3.6,{0.12,0.12,0.11,1})

  local seenCount,ownedCount=0,0
  if GoldCompat.generation=="gen2" then
    local Specials=GoldCompat.engineModule("src.script.gen2.Specials")
    if Specials and type(Specials.dexCounts)=="function" then
      local okCounts,a,b=pcall(Specials.dexCounts,save)
      if okCounts then
        seenCount=tonumber(a) or 0
        ownedCount=tonumber(b) or 0
      end
    end
  else
    seenCount=pokedexSeenCount(save)
    ownedCount=pokedexOwnedCount(save)
  end
  GoldCompat.panelText("POKéDEX",12,61,2.7,{0.34,0.34,0.31,1})
  GoldCompat.panelText(("%d SEEN"):format(seenCount),12,68,3.1,
    {0.08,0.08,0.08,1})
  GoldCompat.panelText(("%d OWNED"):format(ownedCount),42,68,3.1,
    {0.08,0.08,0.08,1})

  local entries=pc.entries or {}
  local index=pc.index or 1
  if pc.picking then
    GoldCompat.panelText("CHANGE BOX",85,31,3.1,{0.34,0.34,0.31,1})
    local first=math.max(1,math.min((pc.pickIndex or 1)-5,9))
    for r=1,6 do
      local n=first+r-1
      local yy=41+(r-1)*12
      local selected=n==(pc.pickIndex or 1)
      if selected then
        G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
        G.setColor(0.10,0.10,0.09,1); roundedRect("fill",83,yy-1,68,10,1.5)
        G.pop()
      end
      GoldCompat.panelText("BOX "..tostring(n),88,yy,3.2,
        selected and {1,1,1,1} or {0.06,0.06,0.06,1})
    end
  else
    for i,e in ipairs(entries) do
      local yy=31+(i-1)*12
      local selected=i==index
      if selected then
        G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
        G.setColor(0.10,0.10,0.09,1); roundedRect("fill",83,yy-1,68,10,1.5)
        G.pop()
      end
      local label=tostring(e.label or e.id or ""):gsub("<PK><MN>","POKéMON")
      GoldCompat.panelText(label,88,yy,2.8,
        selected and {1,1,1,1} or {0.06,0.06,0.06,1},"left",60)
    end
  end

  local footer=pc.message and tostring(pc.message):gsub("\n"," ") or "Choose a PC action."
  GoldCompat.panelText(footer,9,130,3.2,{0.98,0.98,0.96,1},"left",142)
end

function GoldCompat.drawGoldBoxMenu(box)
  local ox,oy,sc=finalCanvas()
  local G=love.graphics
  partyRenderOX,partyRenderOY,partyRenderScale=ox,oy,sc

  G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
  G.setColor(0.94,0.93,0.87,1); G.rectangle("fill",0,0,160,144)
  G.setColor(0.08,0.08,0.08,1); G.rectangle("fill",4,4,152,16)
  G.setColor(0.99,0.985,0.955,1); G.rectangle("fill",5,5,150,14)
  G.setColor(0.08,0.08,0.07,1); G.rectangle("fill",4,127,152,13)
  G.pop()

  local title=box.title and box:title() or "POKéMON PC"
  partyText(tostring(title):gsub("<PK><MN>","POKéMON"),10,6,6,{0.06,0.06,0.06,1})

  local mon=box.panelMon and box:panelMon() or (box.selected and box:selected())
  local pokemon=box.pokemon or (box.game and box.game.data and box.game.data.pokemon) or {}
  local movesData=(box.game and box.game.data and box.game.data.moves) or box.moves or {}

  -- Exact Party-card footprint. The PC no longer maintains a second, slightly
  -- different left-column layout.
  local lx,ly,lw,lh=4,23,74,101
  G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
  partySlotPanel(lx,ly,lw,lh,true)
  G.pop()

  if mon and not mon.isEgg then
    local def=pokemon[mon.species]
    local name=tostring(mon.nickname or mon.name or (def and def.name) or mon.species or "POKéMON")
    local stats=mon.stats or {}

    partyText(name,lx+7,ly+5,5.2,{0.06,0.06,0.06,1})
    local lv="Lv."..tostring(mon.level or "?")
    partyText(lv,lx+lw-7-partyTextWidth(lv,4),ly+6,4,{0.06,0.06,0.06,1})

    local gender=GoldCompat.genderSymbol(mon)

    pcall(GoldCompat.drawCleanResolvedPortrait,box.game,mon,
      ox+(lx+14)*sc,oy+(ly+19)*sc,31*sc,24*sc,"pc")

    local hpMax=math.max(1,mon.maxHp or stats.hp or stats.maxHp or 1)
    local hpNow=tonumber(mon.hp) or 0
    local hpText=tostring(hpNow).."/"..tostring(hpMax)
    local hpY=ly+43
    local hpValueX=lx+lw-7-partyTextWidth(hpText,3)
    local hpBarX=lx+21
    local hpBarW=math.max(17,hpValueX-hpBarX-3)
    partyText("HP",lx+9,hpY,3,{0.08,0.08,0.08,1})
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    local ratio=math.max(0,math.min(1,hpNow/hpMax))
    G.setColor(0.10,0.10,0.09,1); roundedRect("fill",hpBarX,hpY+1,hpBarW,4,1.5)
    G.setColor(0.78,0.76,0.63,1); roundedRect("fill",hpBarX+1,hpY+2,hpBarW-2,2,1)
    if hpNow>0 then
      local r,gg,b,a=hpColor(ratio); G.setColor(r,gg,b,a)
      roundedRect("fill",hpBarX+1,hpY+2,math.max(1,(hpBarW-2)*ratio),2,1)
    end
    G.pop()
    partyText(hpText,hpValueX,hpY,3,{0.08,0.08,0.08,1})

    if gender then
      pcall(GoldCompat.drawGenderIcon,
        ox+(lx+14)*sc,oy+(ly+51.5)*sc,12,gender)
    end

    partyText("EXP",lx+9,ly+55,2.5,{0.34,0.45,0.50,1})
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    local expRatio=partyExpRatio(box.game,mon)
    G.setColor(0.10,0.18,0.24,1); roundedRect("fill",lx+21,ly+56,lw-29,4,1.5)
    G.setColor(0.14,0.28,0.38,1); roundedRect("fill",lx+22,ly+57,lw-31,2,1)
    if expRatio>0 then
      G.setColor(0.08,0.48,0.96,1)
      roundedRect("fill",lx+22,ly+57,(lw-31)*expRatio,2,1)
    end
    G.pop()

    local moves=mon.moves or {}
    local stripX,stripY=lx+6,ly+63
    local stripW=lw-12
    local gap=1
    local moveW=(stripW-gap*3)/4
    local moveH=20
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.70,0.68,0.59,1); G.rectangle("fill",lx+7,ly+60,lw-14,1)
    for i=1,4 do
      local cx=stripX+(i-1)*(moveW+gap)
      G.setColor(0.965,0.95,0.88,1); roundedRect("fill",cx,stripY,moveW,moveH,1.2)
      G.setColor(0.74,0.71,0.61,1); roundedRect("line",cx,stripY,moveW,moveH,1.2)
    end
    G.pop()
    for i=1,4 do
      local entry=moves[i]
      local cx=stripX+(i-1)*(moveW+gap)
      local moveName=partyMoveName(box.game,entry)
      local pp=partyMovePP(box.game,entry)
      local nameSize=2.35
      while nameSize>1.45 and partyTextWidth(moveName,nameSize)>moveW-3 do nameSize=nameSize-0.12 end
      partyText(moveName,cx+1.5,stripY+4,nameSize,{0.06,0.06,0.06,1},"center",moveW-3)
      if pp~="" then partyText(pp,cx+1.5,stripY+13,1.8,{0.24,0.24,0.21,1},"center",moveW-3) end
    end

    local statDefs={
      {"ATK",partyStat(mon,"attack","atk")},
      {"DEF",partyStat(mon,"defense","def")},
      {"SPD",partyStat(mon,"speed","spd")},
      {"SPA",partyStat(mon,"specialAttack","spAtk","special")},
      {"SPD",partyStat(mon,"specialDefense","spDef","special")},
    }
    local statY=ly+lh-15
    local innerX,innerW=lx+6,lw-12
    local colW=innerW/5
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.74,0.72,0.64,1); G.rectangle("fill",lx+7,statY-1,lw-14,1)
    G.pop()
    for i,st in ipairs(statDefs) do
      local cx=innerX+(i-1)*colW
      partyText(st[1],cx+(colW-partyTextWidth(st[1],1.7))/2,statY,1.7,{0.25,0.25,0.22,1})
      local value=tostring(st[2])
      partyText(value,cx+(colW-partyTextWidth(value,2.4))/2,statY+4,2.4,{0.06,0.06,0.06,1})
    end
  else
    partyText(mon and "EGG" or "NO POKéMON",lx+20,ly+45,4,{0.28,0.28,0.25,1})
  end

  -- Right list: keep compact Party-style rows.
  local list=box.list and box:list() or {}
  local first=(box.scroll or 0)+1
  for r=1,5 do
    local idx=first+r-1
    local yy=27+(r-1)*18
    local m=list[idx]
    local selected=idx==(box.index or 1)

    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    partySlotPanel(82,yy,71,16,selected)
    G.pop()

    if m then
      local def=pokemon[m.species]
      local name=m.nickname or m.name or (def and def.name) or m.species or "POKéMON"
      GoldCompat.panelText(name,88,yy+3,2.8,{0.06,0.06,0.06,1},"left",41)
      GoldCompat.panelText("Lv."..tostring(m.level or "?"),131,yy+3,2.35,
        {0.22,0.22,0.20,1},"right",16)
      local g=GoldCompat.genderSymbol(m)
      if g then pcall(GoldCompat.drawGenderIcon,ox+146*sc,oy+(yy+3)*sc,6,g) end
    elseif idx==#list+1 and not (box.phase=="insert") then
      GoldCompat.panelText("CANCEL",88,yy+3,2.8,{0.06,0.06,0.06,1})
    end
  end

  GoldCompat.panelText(box.prompt and box:prompt() or "Choose a POKéMON.",
    9,130,3.3,{0.98,0.98,0.96,1},"left",142)

  if box.phase=="submenu" then
    local labels={"MOVE","STATS","CANCEL"}
    local ix=box.submenuIndex or 1
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    partySlotPanel(109,87,44,36,true)
    for i=1,3 do
      if i==ix then
        G.setColor(0.10,0.10,0.09,1)
        roundedRect("fill",113,90+(i-1)*10,36,9,1)
      end
    end
    G.pop()
    for i,label in ipairs(labels) do
      GoldCompat.panelText(label,117,90+(i-1)*10,2.7,
        i==ix and {1,1,1,1} or {0.06,0.06,0.06,1})
    end
  end
end

function GoldCompat.drawGoldItemPc(pc,winW,winH)
  local ox,oy,sc=finalCanvas()
  local G=love.graphics
  local phase=tostring(pc.phase or "menu")

  local function cleanLine(value)
    return GoldCompat.cleanPcText(value,(pc.playerName and pc:playerName()) or nil)
      :gsub("<NEXT>"," "):gsub("%s+"," ")
  end

  local function currentMessageLines()
    if pc.message then
      if pc.typer and type(pc.typer.lines)=="function" then
        local ok,lines=pcall(pc.typer.lines,pc.typer)
        if ok and type(lines)=="table" then return lines end
      end
      local page=pc.message.pages and pc.message.pages[pc.message.page or 1]
      if type(page)=="string" then return {page} end
      if type(page)=="table" then return page end
    end
    if pc.qtyState and type(pc.qtyState.prompt)=="table" then
      return pc.qtyState.prompt
    end
    if pc.confirm and type(pc.confirm.prompt)=="table" then
      return pc.confirm.prompt
    end
    return nil
  end

  local function drawPromptCard(lines,opts)
    opts=opts or {}
    local x=opts.x or 18
    local y=opts.y or 99
    local w=opts.w or 124
    local h=opts.h or 28
    G.push("all")
    G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.04,0.04,0.04,0.34)
    roundedRect("fill",x+2,y+2,w,h,3)
    G.setColor(0.08,0.08,0.07,1)
    roundedRect("fill",x,y,w,h,3)
    G.setColor(0.99,0.985,0.95,1)
    roundedRect("fill",x+2,y+2,w-4,h-4,2)
    drawUnifiedBorder(x,y,w,h,0)
    G.pop()

    local textLines={}
    for _,line in ipairs(lines or {}) do
      local cleaned=cleanLine(line)
      if cleaned~="" then textLines[#textLines+1]=cleaned end
    end
    if #textLines==0 then textLines={"Choose an item."} end
    local promptTextW=(pc.qtyState or pc.confirm) and (w-54) or (w-14)
    for i=1,math.min(2,#textLines) do
      GoldCompat.panelText(textLines[i],x+7,y+6+(i-1)*7,2.85,
        {0.06,0.06,0.06,1},"left",promptTextW)
    end

    if pc.qtyState then
      local qty=tonumber(pc.qtyState.qty or pc.qtyState.quantity or 1) or 1
      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      G.setColor(0.11,0.28,0.38,1)
      roundedRect("fill",x+w-36,y+5,28,14,2)
      G.pop()
      GoldCompat.panelText(("×%02d"):format(qty),x+w-32,y+9,3.0,
        {1,1,1,1},"center",20)
    elseif pc.confirm then
      local c=tonumber(pc.confirm.choice) or 1
      local qx,qy=x+w-43,y+4
      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      G.setColor(0.90,0.89,0.82,1)
      roundedRect("fill",qx,qy,35,20,2)
      for i=1,2 do
        if i==c then
          G.setColor(0.10,0.10,0.09,1)
          roundedRect("fill",qx+3,qy+2+(i-1)*8,29,7,1)
        end
      end
      G.pop()
      GoldCompat.panelText("YES",qx+8,qy+3,2.2,
        c==1 and {1,1,1,1} or {0.08,0.08,0.08,1})
      GoldCompat.panelText("NO",qx+8,qy+11,2.2,
        c==2 and {1,1,1,1} or {0.08,0.08,0.08,1})
    end
  end

  -- Deposit literally owns a live Gen 2 PACK chooser. Keep its native input
  -- and inventory semantics, but render the same hanging Bag surface the rest
  -- of this mod already uses instead of letting ItemPcMenu's opaque native
  -- draw take over the screen.
  if phase=="deposit" and pc.pack then
    GoldCompat.drawGoldPack(pc.pack,winW,winH,true)

    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.11,0.28,0.38,1)
    roundedRect("fill",8,7,70,12,2)
    G.setColor(0.92,0.47,0.13,1)
    G.rectangle("fill",11,17,64,1.5)
    G.pop()
    GoldCompat.panelText("ITEM STORAGE - DEPOSIT",12,10,2.5,
      {1,1,1,1},"left",62)

    local lines=currentMessageLines()
    if lines or pc.qtyState or pc.confirm then
      drawPromptCard(lines,{x=18,y=100,w=124,h=28})
    end
    return
  end

  -- Main Item PC is a hanging card, not a replacement full-screen canvas.
  -- The overworld therefore stays visible around it just like START, PACK,
  -- Mart and the other mature service overlays in this mod.
  local x,y,w,h=20,7,120,130
  G.push("all")
  G.translate(ox,oy); G.scale(sc,sc)
  G.setColor(0.04,0.04,0.04,0.34)
  roundedRect("fill",x+2,y+2,w,h,4)
  G.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",x,y,w,h,4)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+2,y+2,w-4,h-4,3)
  drawUnifiedBorder(x,y,w,h,1)

  G.setColor(0.11,0.28,0.38,1)
  roundedRect("fill",x+5,y+5,w-10,15,2)
  G.setColor(0.92,0.47,0.13,1)
  G.rectangle("fill",x+8,y+18,w-16,1.5)

  G.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",x+5,y+h-13,w-10,9,2)
  G.pop()

  GoldCompat.panelText("ITEM STORAGE",x+10,y+9,4.0,{1,1,1,1})
  local phaseLabel=phase=="withdraw" and "WITHDRAW"
    or phase=="toss" and "TOSS" or "PLAYER'S PC"
  GoldCompat.panelText(phaseLabel,x+w-45,y+10,2.2,
    {0.84,0.90,0.88,1},"right",33)

  if phase=="withdraw" or phase=="toss" then
    local rows=pc.rows or {}
    local first=(tonumber(pc.scroll) or 0)+1
    local selected=tonumber(pc.listIndex) or 1
    local visible=4
    if selected<first then first=selected end
    if selected>first+visible-1 then first=selected-visible+1 end
    first=math.max(1,math.min(first,math.max(1,(#rows+1)-visible+1)))

    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.90,0.89,0.82,1)
    roundedRect("fill",x+7,y+25,w-14,59,2)
    G.setColor(0.72,0.70,0.62,1)
    roundedRect("line",x+7,y+25,w-14,59,2)
    G.pop()

    for r=1,visible do
      local idx=first+r-1
      local yy=y+31+(r-1)*13
      local row=rows[idx]
      local active=idx==selected
      local switching=idx==(tonumber(pc.switching) or -1)

      if active or switching then
        G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
        if active then
          G.setColor(0.10,0.10,0.09,1)
          roundedRect("fill",x+10,yy-2,w-20,11,1.5)
          G.setColor(0.92,0.47,0.13,1)
          roundedRect("fill",x+11,yy,2,7,0.7)
        else
          G.setColor(0.80,0.55,0.18,0.32)
          roundedRect("fill",x+10,yy-2,w-20,11,1.5)
        end
        G.pop()
      end

      if row then
        local label=tostring(row.name or row.id or "ITEM")
        local col=active and {1,1,1,1} or {0.06,0.06,0.06,1}
        GoldCompat.panelText(label,x+17,yy,3.05,col,"left",67)
        GoldCompat.panelText("×"..tostring(row.count or 1),x+w-29,yy,2.65,
          active and {1,1,1,1} or {0.28,0.28,0.25,1},"right",16)
      elseif idx==#rows+1 then
        GoldCompat.panelText("CANCEL",x+17,yy,3.05,
          active and {1,1,1,1} or {0.06,0.06,0.06,1})
      end
    end

    local current=rows[selected]
    local desc=nil
    if current and type(pc.def)=="function" then
      local ok,def=pcall(pc.def,pc,current.id)
      if ok and type(def)=="table" then desc=def.description end
    end
    local lines=currentMessageLines()
    if not lines and desc then
      desc=cleanLine(desc)
      local f=font(math.max(8,math.floor(2.55*sc*UI_TEXT_SCALE+0.5)))
      local _,wrapped=f:getWrap(desc,100*sc)
      lines={wrapped[1] or desc,wrapped[2]}
    end
    drawPromptCard(lines or {
      phase=="withdraw" and "Choose an item to withdraw."
        or "Choose an item to toss."
    },{x=x+7,y=y+89,w=w-14,h=24})

    local footer=pc.switching and "A PLACE   B CANCEL"
      or "A SELECT   SELECT MOVE   B BACK"
    GoldCompat.panelText(footer,x+10,y+h-11,1.65,
      {0.98,0.98,0.96,1},"left",w-20)
  else
    local entries=pc.entries or {}
    local selected=tonumber(pc.index) or 1
    local count=#entries
    local listH=math.min(60,math.max(40,count*9+6))

    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.90,0.89,0.82,1)
    roundedRect("fill",x+8,y+27,w-16,listH,2)
    G.setColor(0.72,0.70,0.62,1)
    roundedRect("line",x+8,y+27,w-16,listH,2)
    G.pop()

    for i,entry in ipairs(entries) do
      local yy=y+33+(i-1)*9
      local active=i==selected
      if active then
        G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
        G.setColor(0.10,0.10,0.09,1)
        roundedRect("fill",x+12,yy-2,w-24,8,1.3)
        G.setColor(0.92,0.47,0.13,1)
        roundedRect("fill",x+13,yy,2,4.5,0.7)
        G.pop()
      end
      local label=entry and entry.label or ""
      if entry and entry.builtin then
        local ok,res=pcall(Strings,label)
        if ok and res then label=res end
      end
      label=cleanLine(label)
      GoldCompat.panelText(label,x+19,yy,2.8,
        active and {1,1,1,1} or {0.06,0.06,0.06,1},"left",w-34)
    end

    local lines=currentMessageLines() or {"What do you want to do?"}
    drawPromptCard(lines,{x=x+7,y=y+90,w=w-14,h=24})
    GoldCompat.panelText("A CONFIRM   B BACK",x+10,y+h-11,1.7,
      {0.98,0.98,0.96,1},"left",w-20)
  end
end

function GoldCompat.installGoldServiceUI()
  if GoldCompat.generation~="gen2" or GoldCompat.serviceUiInstalled then return end

  local okPack,PackMenu=pcall(require,"src.ui.gen2.PackMenu")
  if okPack and type(PackMenu)=="table" and not PackMenu.__gen3uiVisualPatched then
    PackMenu.__gen3uiVisualPatched=true
    PackMenu.__gen3uiOriginalOpaque=PackMenu.isOpaque
    PackMenu.__gen3uiOriginalNew=PackMenu.new
    PackMenu.__gen3uiOriginalDraw=PackMenu.draw
    PackMenu.__gen3uiOriginalDrawWidescreen=PackMenu.drawWidescreen
    PackMenu.isOpaque=false
    PackMenu.wantsFillScale=function() return false end
    PackMenu.drawsWidescreen=function() return false end
    PackMenu.new=function(...)
      local self=PackMenu.__gen3uiOriginalNew(...)
      self.isOpaque=false
      self.__gen3uiGoldOverlayKind="pack"
      return self
    end
    -- FOUND: these two used to just stub out the native draw entirely
    -- (self.__gen3uiGoldOverlayKind="pack"; return) instead of running it
    -- invisibly -- the exact "skip native draw" anti-pattern already found
    -- and fixed via runDrawInvisible on every other hanging screen (Options,
    -- TrainerCard, SaveMenu, ManagerState, the generic P.patchClass service
    -- screens). Skipping the real draw call here meant that, with a 3D
    -- battle renderer (e.g. Colosseum Battle Environments) active behind the
    -- Bag, whatever per-frame chaining that renderer's own hook relies on
    -- (typically piggybacked on the native menu class's own draw/
    -- drawWidescreen call) never ran, which is a very plausible source of
    -- the reported "glass/fisheye" warped-background look: the 3D layer was
    -- being left to render from a stale or half-updated state every frame
    -- the Bag was open. Running the original invisibly keeps that lifecycle
    -- intact while guaranteeing no native Pack pixels reach the frame.
    PackMenu.draw=function(self,...)
      self.__gen3uiGoldOverlayKind="pack"
      if type(PackMenu.__gen3uiOriginalDraw)=="function" then
        return runDrawInvisible(PackMenu.__gen3uiOriginalDraw,self,...)
      end
    end
    PackMenu.drawWidescreen=function(self,winW,winH,...)
      self.__gen3uiGoldOverlayKind="pack"
      if type(PackMenu.__gen3uiOriginalDrawWidescreen)=="function" then
        return runDrawInvisible(
          PackMenu.__gen3uiOriginalDrawWidescreen,self,winW,winH,...)
      end
    end
  end

  local okMart,MartMenu=pcall(require,"src.ui.gen2.MartMenu")
  if okMart and type(MartMenu)=="table" and not MartMenu.__gen3uiVisualPatched then
    MartMenu.__gen3uiVisualPatched=true
    MartMenu.__gen3uiOriginalNew=MartMenu.new
    MartMenu.__gen3uiOriginalDraw=MartMenu.draw
    MartMenu.__gen3uiOriginalDrawWidescreen=MartMenu.drawWidescreen
    MartMenu.isOpaque=false
    MartMenu.wantsFillScale=function() return false end
    MartMenu.drawsWidescreen=function() return false end
    MartMenu.new=function(...)
      local self=MartMenu.__gen3uiOriginalNew(...)
      self.isOpaque=false
      self.__gen3uiGoldOverlayKind="mart"
      return self
    end
    -- Same fix as PackMenu above: run the native draw invisibly instead of
    -- skipping it outright.
    MartMenu.draw=function(self,...)
      self.__gen3uiGoldOverlayKind="mart"
      if type(MartMenu.__gen3uiOriginalDraw)=="function" then
        return runDrawInvisible(MartMenu.__gen3uiOriginalDraw,self,...)
      end
    end
    MartMenu.drawWidescreen=function(self,winW,winH,...)
      self.__gen3uiGoldOverlayKind="mart"
      if type(MartMenu.__gen3uiOriginalDrawWidescreen)=="function" then
        return runDrawInvisible(
          MartMenu.__gen3uiOriginalDrawWidescreen,self,winW,winH,...)
      end
    end
  end

  local okCenter,CenterPcMenu=pcall(require,"src.ui.gen2.CenterPcMenu")
  if okCenter and type(CenterPcMenu)=="table"
      and not CenterPcMenu.__gen3uiVisualPatched then
    CenterPcMenu.__gen3uiVisualPatched=true
    CenterPcMenu.__gen3uiOriginalNew=CenterPcMenu.new
    CenterPcMenu.__gen3uiOriginalDraw=CenterPcMenu.draw
    CenterPcMenu.__gen3uiOriginalDrawWidescreen=CenterPcMenu.drawWidescreen
    CenterPcMenu.isOpaque=false
    CenterPcMenu.wantsFillScale=function() return false end
    CenterPcMenu.drawsWidescreen=function() return false end
    CenterPcMenu.new=function(...)
      local self=CenterPcMenu.__gen3uiOriginalNew(...)
      self.isOpaque=false
      self.__gen3uiGoldOverlayKind="centerpc"
      return self
    end
    -- Same fix as PackMenu/MartMenu above: run the native draw invisibly
    -- instead of skipping it outright.
    CenterPcMenu.draw=function(self,...)
      self.__gen3uiGoldOverlayKind="centerpc"
      if type(CenterPcMenu.__gen3uiOriginalDraw)=="function" then
        return runDrawInvisible(CenterPcMenu.__gen3uiOriginalDraw,self,...)
      end
    end
    CenterPcMenu.drawWidescreen=function(self,winW,winH,...)
      self.__gen3uiGoldOverlayKind="centerpc"
      if type(CenterPcMenu.__gen3uiOriginalDrawWidescreen)=="function" then
        return runDrawInvisible(
          CenterPcMenu.__gen3uiOriginalDrawWidescreen,self,winW,winH,...)
      end
    end
  end

  local okPc,PcMenu=pcall(require,"src.ui.gen2.PcMenu")
  if okPc and type(PcMenu)=="table" and not PcMenu.__gen3uiVisualPatched then
    PcMenu.__gen3uiVisualPatched=true
    PcMenu.__gen3uiOriginalDrawWidescreen=PcMenu.drawWidescreen
    PcMenu.drawWidescreen=function(self,winW,winH)
      return GoldCompat.drawGoldPcRoot(self)
    end
  end

  local okBox,BoxMenu=pcall(require,"src.ui.gen2.BoxMenu")
  if okBox and type(BoxMenu)=="table" and not BoxMenu.__gen3uiVisualPatched then
    BoxMenu.__gen3uiVisualPatched=true
    BoxMenu.__gen3uiOriginalDrawWidescreen=BoxMenu.drawWidescreen
    BoxMenu.drawWidescreen=function(self,winW,winH)
      return GoldCompat.drawGoldBoxMenu(self)
    end
  end

  -- Gen 2's player Item PC is a dedicated ItemPcMenu class.  Its native
  -- setPhase() deliberately flips instance.isOpaque back ON for withdraw /
  -- deposit / toss, which undid every earlier class-level isOpaque=false patch
  -- the moment the player actually entered storage.  Patch the state transition
  -- itself, not just construction, and claim both draw entry points so the
  -- native logic continues running while only our hanging presentation is seen.
  local okItemPc,ItemPcMenu=pcall(require,"src.ui.gen2.ItemPcMenu")
  if okItemPc and type(ItemPcMenu)=="table" then
    GoldCompat.itemPcClass=ItemPcMenu
  end
  if okItemPc and type(ItemPcMenu)=="table"
      and not ItemPcMenu.__gen3uiVisualPatched then
    ItemPcMenu.__gen3uiVisualPatched=true

    ItemPcMenu.__gen3uiOriginalNew=ItemPcMenu.new
    ItemPcMenu.__gen3uiOriginalDraw=ItemPcMenu.draw
    ItemPcMenu.__gen3uiOriginalDrawPanel=ItemPcMenu.drawPanel
    ItemPcMenu.__gen3uiOriginalSetPhase=ItemPcMenu.setPhase
    ItemPcMenu.__gen3uiOriginalWantsFillScale=ItemPcMenu.wantsFillScale
    ItemPcMenu.__gen3uiOriginalDrawsWidescreen=ItemPcMenu.drawsWidescreen

    ItemPcMenu.isOpaque=false

    ItemPcMenu.new=function(...)
      local self=ItemPcMenu.__gen3uiOriginalNew(...)
      if featureEnabled("revampedItemPCUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="itempc"
      end
      return self
    end

    ItemPcMenu.setPhase=function(self,phase,...)
      local out={ItemPcMenu.__gen3uiOriginalSetPhase(self,phase,...)}
      if featureEnabled("revampedItemPCUI") then
        -- Native CLEARS_SCREEN marks withdraw/deposit/toss opaque here.  Force
        -- it back to hanging every time so the live overworld remains visible.
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="itempc"
      end
      return unpack(out)
    end

    ItemPcMenu.wantsFillScale=function(self,...)
      if featureEnabled("revampedItemPCUI") then return false end
      if type(ItemPcMenu.__gen3uiOriginalWantsFillScale)=="function" then
        return ItemPcMenu.__gen3uiOriginalWantsFillScale(self,...)
      end
      return true
    end

    ItemPcMenu.drawsWidescreen=function(self,...)
      if featureEnabled("revampedItemPCUI") then return false end
      if type(ItemPcMenu.__gen3uiOriginalDrawsWidescreen)=="function" then
        return ItemPcMenu.__gen3uiOriginalDrawsWidescreen(self,...)
      end
      return false
    end

    ItemPcMenu.drawPanel=function(self,...)
      if featureEnabled("revampedItemPCUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="itempc"
        if type(ItemPcMenu.__gen3uiOriginalDrawPanel)=="function" then
          return runDrawInvisible(ItemPcMenu.__gen3uiOriginalDrawPanel,self,...)
        end
        return
      end
      if type(ItemPcMenu.__gen3uiOriginalDrawPanel)=="function" then
        return ItemPcMenu.__gen3uiOriginalDrawPanel(self,...)
      end
    end

    ItemPcMenu.draw=function(self,...)
      if featureEnabled("revampedItemPCUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="itempc"
        if type(ItemPcMenu.__gen3uiOriginalDraw)=="function" then
          return runDrawInvisible(ItemPcMenu.__gen3uiOriginalDraw,self,...)
        end
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      if type(ItemPcMenu.__gen3uiOriginalDraw)=="function" then
        return ItemPcMenu.__gen3uiOriginalDraw(self,...)
      end
    end

    if GoldCompat.mod and GoldCompat.mod.log then
      GoldCompat.mod.log:info(
        "Gen 3 UI: Gen2 Item PC fully claimed (new/setPhase/draw/drawPanel); "
        .."opaque native storage canvas disabled while ITEM STORAGE PC UI is on")
    end
  elseif GoldCompat.mod and GoldCompat.mod.log then
    GoldCompat.mod.log:info("Gen 3 UI: src.ui.gen2.ItemPcMenu not found on "
      .."this engine build -- relying on the generic Menu/ListMenu "
      .."title-recognizer for Item PC storage instead")
  end

  GoldCompat.serviceUiInstalled=true
end

-- The vanilla location/area-name banner that pops up on entering a new map
-- is not a pushed menu/state (unlike everything else patched in this file),
-- so it has no natural place on the state stack to find and gate the way
-- OptionsMenu/PackMenu/ElevatorMenu etc. are. There is no Gen1Recomp source
-- available to this mod to get its real module path, so every plausible
-- candidate is tried using this codebase's own already-confirmed naming
-- convention (src.ui.<Name>, src.ui.gen2.<Name>, src.render.<Name>,
-- src.world.<Name> -- see the require() calls throughout this file for
-- BagMenu/ChoiceBox/TextBox/PikachuFollower/Pokegear/etc., which is exactly
-- how every one of those was originally found). Whichever candidate(s)
-- actually resolve get their draw/drawWidescreen suppressed, gated on this
-- mod's own banner feature so the native one only disappears when ours is
-- actually on to replace it. This is a best-effort guess, not a confirmed
-- fix -- the result (which candidates resolved, if any) is logged once so a
-- single reproduction either confirms it worked or hands back the next lead.
function GoldCompat.suppressNativeLocationBanner(mod)
  if GoldCompat.__gen3uiBannerSuppressAttempted then return end
  GoldCompat.__gen3uiBannerSuppressAttempted=true

  -- CONFIRMED against the real Gen1Recomp engine source (v2.1.18): the
  -- native location banner is src.world.gen2.MapNameSign -- internally
  -- named after Pokemon Crystal's map_name_sign.asm. Every earlier attempt
  -- here (through v2.1.17) guessed at ~20 plausible-sounding module paths
  -- (LocationBanner/AreaBanner/MapBanner/TownSign/etc. under src.world,
  -- src.render and src.ui) without engine source to check against; none of
  -- them were real. Two things fell out of actually reading MapNameSign.lua:
  -- (1) MapNameSign.draw is a MODULE-LEVEL function stored directly on the
  -- table require() returns, not a per-instance method on a class -- it is
  -- called as MapNameSign.draw(world, w, h, posLift) from
  -- src/world/gen2/World.lua, so patching .draw on the required table (which
  -- require() caches and hands back everywhere, including inside World.lua's
  -- own local) intercepts that exact call. (2) MapNameSign.draw (and .init)
  -- both bail out immediately unless GameVersion.engine()=="crystal" -- this
  -- banner only ever appears on Crystal saves. Gold and Silver saves never
  -- draw one at all, so there is nothing to suppress there, and this patch
  -- being a no-op on Gold/Silver is correct, not a miss.
  local ok,MapNameSign=pcall(require,"src.world.gen2.MapNameSign")
  if ok and type(MapNameSign)=="table" and type(MapNameSign.draw)=="function"
      and not MapNameSign.__gen3uiBannerPatched then
    MapNameSign.__gen3uiBannerPatched=true
    local original=MapNameSign.draw
    MapNameSign.draw=function(world,w,h,posLift,...)
      if featureEnabled("revampedLocationBannerUI") then return end
      return original(world,w,h,posLift,...)
    end
    if mod.log then
      mod.log:info("Gen 3 UI: suppressing native Crystal location banner "
        .."(src.world.gen2.MapNameSign.draw)")
    end
  elseif mod.log then
    mod.log:info("Gen 3 UI: src.world.gen2.MapNameSign not found on this "
      .."engine build -- native location banner left unsuppressed")
  end
end


function GoldCompat.countTruthy(t)
  local n=0
  for _,v in pairs(t or {}) do if v then n=n+1 end end
  return n
end

function GoldCompat.drawGoldSave(saveMenu)
  local ox,oy,sc=finalCanvas()
  local G=love.graphics
  local Save2=GoldCompat.requiredEngineModule("src.core.gen2.Save")
  local summary=Save2.summary and Save2.summary(saveMenu.save) or nil

  local x,y,w,h=42,18,76,108
  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  G.setColor(0.04,0.04,0.04,0.36)
  roundedRect("fill",x+2,y+2,w,h,4)
  G.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",x,y,w,h,4)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+2,y+2,w-4,h-4,3)
  drawUnifiedBorder(x,y,w,h,1)

  G.setColor(0.11,0.28,0.38,1)
  roundedRect("fill",x+5,y+5,w-10,14,2)
  G.setColor(0.84,0.82,0.73,1)
  G.rectangle("fill",x+7,y+62,w-14,1)

  -- Prompt card.
  G.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",x+5,y+68,w-10,31,2)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+7,y+70,w-14,27,1.5)
  G.pop()

  GoldCompat.panelText("SAVE",x+8,y+9,4.5,{1,1,1,1})
  if summary then
    GoldCompat.panelText("PLAYER",x+8,y+25,2.4,{0.38,0.38,0.35,1})
    GoldCompat.panelText(summary.name or "GOLD",x+30,y+25,3.0,
      {0.08,0.08,0.08,1},"left",34)
    GoldCompat.panelText("BADGES",x+8,y+35,2.4,{0.38,0.38,0.35,1})
    GoldCompat.panelText(tostring(summary.badges or 0),x+55,y+35,3.0,
      {0.08,0.08,0.08,1},"right",10)
    GoldCompat.panelText("POKéDEX",x+8,y+45,2.4,{0.38,0.38,0.35,1})
    GoldCompat.panelText(tostring(summary.caught or 0),x+55,y+45,3.0,
      {0.08,0.08,0.08,1},"right",10)
    GoldCompat.panelText("TIME",x+8,y+55,2.4,{0.38,0.38,0.35,1})
    GoldCompat.panelText(("%d:%02d"):format(summary.hours or 0,summary.minutes or 0),
      x+43,y+55,3.0,{0.08,0.08,0.08,1},"right",22)
  end

  local lines=saveMenu.prompt and saveMenu:prompt() or {"Save the game?",""}
  for i=1,math.min(2,#lines) do
    GoldCompat.panelText(lines[i],x+11,y+75+(i-1)*8,2.8,
      {0.07,0.07,0.07,1},"left",w-22)
  end

  if saveMenu.phase=="confirm" or saveMenu.phase=="overwrite" then
    local c=saveMenu.choice or 1
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    for i=1,2 do
      local bx=x+13+(i-1)*27
      if i==c then
        G.setColor(0.11,0.28,0.38,1)
        roundedRect("fill",bx,y+101,24,9,1.5)
      else
        G.setColor(0.86,0.84,0.77,1)
        roundedRect("fill",bx,y+101,24,9,1.5)
      end
    end
    G.pop()
    GoldCompat.panelText("YES",x+13,y+103,2.6,
      c==1 and {1,1,1,1} or {0.18,0.18,0.16,1},"center",24)
    GoldCompat.panelText("NO",x+40,y+103,2.6,
      c==2 and {1,1,1,1} or {0.18,0.18,0.16,1},"center",24)
  end
end

function GoldCompat.goldOptionValue(menu,row)
  if row.frame then return "TYPE "..tostring(menu.options.frame or 1) end
  if row.text then
    local ok,v=pcall(row.text,menu.options)
    if ok then return tostring(v) end
  end
  if row.values then
    local v=menu.options[row.key]
    return tostring((row.display and row.display[v]) or v or "")
  end
  if type(row.value)=="function" then
    local ok,v=pcall(row.value,menu.game)
    if ok then return tostring(v) end
  end
  return ""
end

function GoldCompat.trainerPortraitShader()
  if GoldCompat.__trainerPortraitShader~=nil then
    return GoldCompat.__trainerPortraitShader or nil
  end
  local ok,shader=pcall(love.graphics.newShader,[[
    vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
      vec4 px=Texel(tex,tc)*color;
      if (px.r>0.965 && px.g>0.965 && px.b>0.965) px.a=0.0;
      if (px.b>0.80 && px.b>px.r*1.35 && px.b>px.g*1.25) px.a=0.0;
      return px;
    }
  ]])
  GoldCompat.__trainerPortraitShader=ok and shader or false
  return GoldCompat.__trainerPortraitShader or nil
end

function GoldCompat.trainerOwnedCount(save)
  local n=#(save.party or {})
  for _,box in pairs(save.boxes or {}) do
    if type(box)=="table" then n=n+#box end
  end
  return n
end

function GoldCompat.drawNativeTrainerCanvas(card)
  local G=love.graphics
  if not card.__gen3uiNativeCanvas then
    local ok,c=pcall(G.newCanvas,160,144)
    if ok then
      card.__gen3uiNativeCanvas=c
      if c.setFilter then pcall(c.setFilter,c,"nearest","nearest") end
    end
  end
  local canvas=card.__gen3uiNativeCanvas
  if not canvas then return nil end

  local old=G.getCanvas()
  G.push("all")
  G.setCanvas(canvas)
  G.clear(1,1,1,1)
  G.origin()
  local Trainer=GoldCompat.requiredEngineModule("src.ui.gen2.TrainerCard")
  if Trainer.__gen3uiOriginalDrawPanel then
    pcall(Trainer.__gen3uiOriginalDrawPanel,card)
  end
  G.setCanvas(old)
  G.pop()
  return canvas
end

function GoldCompat.drawGoldUISettings(state)
  local rows=state.rows or {}
  local count=#rows
  if count<=0 then return end

  local index=math.max(1,math.min(count,state.index or 1))
  local visible=math.min(7,count)
  local first=math.max(1,(state.scroll or 0)+1)

  if index<first then first=index end
  if index>first+visible-1 then first=index-visible+1 end
  first=math.max(1,math.min(first,math.max(1,count-visible+1)))

  -- Deliberately self-contained: this renderer only uses helpers that already
  -- called a later local helper (gen1HangingFrame), which is not in lexical
  -- scope here and can resolve to nil at runtime.
  local G=love.graphics
  local ox,oy,sc=finalCanvas()

  -- Row label draws at 2.85 below -- dynamic to match TEXT SIZE (General
  -- Sweep, v2.1.28). This panel already sizes itself (`h`) from rowH*visible,
  -- so growing rowH here needs no separate shrink-to-fit step.
  local rowH=GoldCompat.dynamicRowHeight(2.85,9,3)
  local w=112
  local h=24+visible*rowH+11
  local x=44
  local y=math.max(4,math.floor((144-h)/2))

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)

  -- Shadow.
  G.setColor(0.05,0.05,0.05,0.34)
  G.rectangle("fill",x+2,y+2,w,h)

  -- Same hanging-card language as START / Options.
  G.setColor(0.08,0.08,0.07,1)
  G.rectangle("fill",x,y,w,h)
  G.setColor(0.99,0.985,0.95,1)
  G.rectangle("fill",x+2,y+2,w-4,h-4)
  drawUnifiedBorder(x,y,w,h,0)

  -- Dark header strip.
  G.setColor(0.10,0.10,0.09,1)
  G.rectangle("fill",x+4,y+4,w-8,12)

  -- Selected row.
  for r=1,visible do
    local idx=first+r-1
    if idx<=count then
      local yy=y+20+(r-1)*rowH
      if idx==index then
        G.setColor(0.11,0.28,0.38,1)
        roundedRect("fill",x+4,yy-1,w-8,rowH-1,2)
        G.setColor(1.00,0.36,0.16,1)
        G.rectangle("fill",x+4,yy-1,1.5,rowH-1)
      end
    end
  end
  G.pop()

  finalText("GEN 3 UI",x+8,y+6,4.6,{1,1,1,1},ox,oy,sc)

  for r=1,visible do
    local idx=first+r-1
    local row=rows[idx]
    if row then
      local yy=y+20+(r-1)*rowH
      local selected=idx==index
      local label=tostring(row.label or row.name or "")
      local value=DexUI.optionDisplay(row)

      finalText(label,x+8,yy+1,2.85,
        selected and {1,1,1,1} or {0.06,0.06,0.06,1},
        ox,oy,sc,"left",73)

      if value and tostring(value)~="" then
        finalText(tostring(value),x+83,yy+1,2.65,
          selected and {1,1,1,1} or {0.25,0.25,0.22,1},
          ox,oy,sc,"right",20)
      end
    end
  end

  if first>1 then
    finalText("▲",x+w-10,y+18,2.2,
      {0.32,0.32,0.29,1},ox,oy,sc)
  end
  if first+visible-1<count then
    finalText("▼",x+w-10,y+h-12,2.2,
      {0.32,0.32,0.29,1},ox,oy,sc)
  end

  finalText("A: CHANGE   B: BACK",x+8,y+h-6,2.15,
    {0.32,0.32,0.29,1},ox,oy,sc)
end


local function screenFeatureEnabled(key)
  return featureEnabled(key)
end

local function goldScreenEnabled(key)
  return GoldCompat.generation=="gen2" and screenFeatureEnabled(key)
end

local function callOriginal(method,self,...)
  if type(method)=="function" then
    return method(self,...)
  end
end


local function gen1HangingFrame(x,y,w,h,title)
  local g=love.graphics
  local ox,oy,sc=finalCanvas()
  g.push("all")
  g.translate(ox,oy)
  g.scale(sc,sc)

  g.setColor(0.05,0.05,0.05,0.34)
  g.rectangle("fill",x+2,y+2,w,h)
  g.setColor(0.08,0.08,0.07,1)
  g.rectangle("fill",x,y,w,h)
  g.setColor(0.99,0.985,0.95,1)
  g.rectangle("fill",x+2,y+2,w-4,h-4)
  drawUnifiedBorder(x,y,w,h,0)

  g.setColor(0.10,0.10,0.09,1)
  g.rectangle("fill",x+4,y+4,w-8,12)
  g.pop()

  finalText(title,x+8,y+6,4.6,{1,1,1,1},ox,oy,sc)
  return ox,oy,sc
end

function GoldCompat.gen1ManagerRows(manager)
  if manager.screen=="options" then
    return manager.optionRows or {}
  end
  if type(manager.rowsForScreen)=="function" then
    local ok,rows=pcall(manager.rowsForScreen,manager)
    if ok and type(rows)=="table" then return rows end
  end
  return manager.mods or {}
end

function GoldCompat.drawGen1OptionsHanging(menu)
  -- CONFIRMED against the real src/ui/OptionsMenu.lua: the native class
  -- keeps two different lists -- self.rows is the full flat ~30-entry
  -- option list, while self.view is the list ACTUALLY being navigated
  -- (either the ~9-entry top-level group list, or a submenu's own row list
  -- once one is pushed -- where view and rows are the same array). Native
  -- input handling always walks `self.view or self.rows` (see
  -- OptionsMenu:update()), and self.index/self.scroll are indices into
  -- THAT list. Drawing menu.rows unconditionally here (the previous
  -- behavior) meant the top-level Options screen rendered the flat 30-item
  -- list while the highlight/cursor position was actually an index into the
  -- unrelated 9-item grouped list -- the visible selection and what
  -- LEFT/RIGHT/A actually acted on had nothing to do with each other.
  local rows=menu.view or menu.rows or {}
  local total=#rows+1
  local index=math.max(1,math.min(total,menu.index or 1))
  local visible=math.min(7,total)
  local first=math.max(1,math.min(index-2,math.max(1,total-visible+1)))

  -- Row label draws at 3.0 below -- dynamic to match TEXT SIZE (General
  -- Sweep, v2.1.28). This panel already sizes itself (`h`) from rowH*visible.
  local rowH=GoldCompat.dynamicRowHeight(3.0,10,3)
  local w=108
  local h=22+visible*rowH+10
  local x=48
  local y=math.max(4,math.floor((144-h)/2))
  local ox,oy,sc=gen1HangingFrame(x,y,w,h,"OPTIONS")
  local g=love.graphics

  for r=1,visible do
    local idx=first+r-1
    if idx<=total then
      local row=rows[idx]
      local isCancel=idx==total
      local yy=y+19+(r-1)*rowH
      local selected=idx==index

      if selected then
        g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
        g.setColor(0.11,0.28,0.38,1)
        roundedRect("fill",x+4,yy-1,w-8,rowH-1,2)
        g.setColor(1.00,0.36,0.16,1)
        g.rectangle("fill",x+4,yy-1,1.5,rowH-1)
        g.pop()
      end

      local label=isCancel and "CANCEL" or tostring(row and row.label or "")
      local value=""
      if row then value=tostring(GoldCompat.goldOptionValue(menu,row) or "") end

      -- Full labels: give the label column most of the card instead of
      -- truncating it to ten 8px glyphs.
      finalText(label,x+8,yy+1,3.0,
        selected and {1,1,1,1} or {0.06,0.06,0.06,1},
        ox,oy,sc,"left",72)
      if value~="" then
        finalText(value,x+79,yy+1,2.85,
          selected and {1,1,1,1} or {0.25,0.25,0.22,1},
          ox,oy,sc,"right",21)
      end
    end
  end

  finalText("LEFT / RIGHT: CHANGE   A: SELECT   B: BACK",
    x+7,y+h-6,2.15,{0.32,0.32,0.29,1},ox,oy,sc,"left",w-14)
end

function GoldCompat.drawGen1ModManagerHanging(manager)
  local rows=GoldCompat.gen1ManagerRows(manager)
  local cursor=math.max(1,manager.cursor or 1)
  local visible=math.min(7,math.max(1,#rows))
  local first

  if manager.screen=="options" then
    first=math.max(1,(manager.scroll or 0)+1)
  else
    first=math.max(1,manager.scroll or 1)
  end
  if cursor<first+1 then first=math.max(1,cursor-1) end
  if cursor>first+visible-2 then first=math.max(1,cursor-visible+2) end
  first=math.min(first,math.max(1,#rows-visible+1))

  -- Row label draws at 2.85 below -- dynamic to match TEXT SIZE (General
  -- Sweep, v2.1.28). This panel already sizes itself (`h`) from rowH*visible.
  local rowH=GoldCompat.dynamicRowHeight(2.85,9,3)
  local w=112
  local h=34+visible*rowH+12
  local x=44
  local y=math.max(4,math.floor((144-h)/2))
  local ox,oy,sc=gen1HangingFrame(x,y,w,h,
    tostring(manager.banner or "MOD MANAGER"))
  local g=love.graphics

  if manager.screen=="list" then
    local tabs={"MODS","PROFILES","ERRORS"}
    for i,label in ipairs(tabs) do
      local tx=x+6+(i-1)*34
      local selected=i==(manager.tab or 1)
      g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
      g.setColor(selected and 0.11 or 0.86,
                 selected and 0.28 or 0.84,
                 selected and 0.38 or 0.77,1)
      roundedRect("fill",tx,y+18,31,8,1.5)
      g.pop()
      finalText(label,tx,y+20,2.25,
        selected and {1,1,1,1} or {0.23,0.23,0.21,1},
        ox,oy,sc,"center",31)
    end
  else
    local subtitle=tostring(manager.screen or "MODS"):upper()
    finalText(subtitle,x+8,y+20,2.5,{0.30,0.30,0.27,1},ox,oy,sc)
  end

  local baseY=y+31
  for r=1,visible do
    local idx=first+r-1
    local row=rows[idx]
    if row then
      local yy=baseY+(r-1)*rowH
      local selected=idx==cursor and not (type(row)=="table" and row.header)

      if selected then
        g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
        g.setColor(0.11,0.28,0.38,1)
        roundedRect("fill",x+4,yy-1,w-8,rowH-1,2)
        g.setColor(1.00,0.36,0.16,1)
        g.rectangle("fill",x+4,yy-1,1.5,rowH-1)
        g.pop()
      end

      local label
      if type(row)=="string" then label=row
      elseif type(row)=="table" then
        label=row.label or row.name or row.id or row.key or row.title or ""
      else label=tostring(row) end

      finalText(tostring(label),x+8,yy+1,
        (type(row)=="table" and row.header) and 2.55 or 2.85,
        selected and {1,1,1,1}
          or ((type(row)=="table" and row.header)
              and {0.36,0.36,0.32,1} or {0.06,0.06,0.06,1}),
        ox,oy,sc,"left",84)

      if type(row)=="table" and (row.value~=nil or row.status~=nil
          or row.key~=nil) then
        local raw=row.value~=nil and row.value or row.status

        -- ManagerState option rows may expose a getter closure rather than a
        -- pre-rendered value. Resolve it instead of printing "function: 0x...".
        if type(raw)=="function" then
          local ok,v=pcall(raw,row,manager)
          if not ok then ok,v=pcall(raw,manager) end
          if not ok then ok,v=pcall(raw) end
          raw=ok and v or nil
        end

        -- Our own registered rows can always be resolved from the live option
        -- store, which also guarantees toggles render as ON/OFF.
        if row.key and OPTION_DEFAULTS[row.key]~=nil then
          raw=optionValue(row.key)
        end

        local value=""
        if type(raw)=="boolean" then
          value=raw and "ON" or "OFF"
        elseif raw~=nil and type(raw)~="function" then
          value=tostring(raw):upper()
        end

        if value~="" then
          finalText(value,x+91,yy+1,2.55,
            selected and {1,1,1,1} or {0.28,0.28,0.25,1},
            ox,oy,sc,"right",14)
        end
      end
    end
  end

  if #rows==0 then
    finalText("No entries available.",x+9,y+55,2.9,
      {0.30,0.30,0.27,1},ox,oy,sc)
  end

  finalText("A: SELECT   B: BACK",x+8,y+h-6,2.25,
    {0.32,0.32,0.29,1},ox,oy,sc)
end

function GoldCompat.drawGen1TrainerCardHanging(card)
  local game=card and card.game
  local save=(card and (card.save or (game and game.save))) or nil
  if not save then return end

  local x,y,w,h=30,12,126,120
  local ox,oy,sc=gen1HangingFrame(x,y,w,h,"TRAINER CARD")
  local g=love.graphics

  -- Two compact cards, visually matching Party/START rather than the old
  -- native full-screen Trainer Card.
  g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
  g.setColor(0.12,0.12,0.11,1)
  roundedRect("fill",x+5,y+20,47,88,3)
  roundedRect("fill",x+56,y+20,65,88,3)
  g.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+7,y+22,43,84,2)
  roundedRect("fill",x+58,y+22,61,84,2)
  g.setColor(0.76,0.62,0.30,1)
  roundedRect("line",x+8,y+23,41,82,2)
  roundedRect("line",x+59,y+23,59,82,2)
  g.pop()

  -- Native portrait artwork, but no native card chrome.
  if card.pic then
    g.push("all")
    g.origin()
    g.setColor(1,1,1,1)
    local iw,ih=card.pic:getDimensions()
    local targetH=42*sc
    local scale=targetH/math.max(1,ih)
    local dw=iw*scale
    local dx=math.floor(ox+(x+28.5)*sc-dw/2)
    local dy=math.floor(oy+(y+28)*sc)
    g.draw(card.pic,dx,dy,0,scale,scale)
    if card.picTrueColor then
      local PaletteFX=GoldCompat.engineModule("src.render.PaletteFX")
      if PaletteFX and type(PaletteFX.markTrueColor)=="function" then
        pcall(PaletteFX.markTrueColor,dx,dy,dw,targetH)
      end
    end
    g.pop()
  end

  local player=save.player or {}
  local caught=0
  for _ in pairs(save.pokedex and save.pokedex.owned or {}) do caught=caught+1 end
  local t=math.floor(save.playTime or 0)
  local badgeCount=0
  local Badges=GoldCompat.engineModule("src.inventory.Badges")
  if Badges and type(Badges.count)=="function" then
    local ok,count=pcall(Badges.count,game.data,save)
    if ok then badgeCount=tonumber(count) or 0 end
  end

  finalText(tostring(player.name or "RED"),x+11,y+72,4.0,
    {0.06,0.06,0.06,1},ox,oy,sc)
  finalText("TRAINER ID",x+11,y+82,2.4,
    {0.36,0.36,0.32,1},ox,oy,sc)
  finalText(("%05d"):format(tonumber(player.id) or 0),x+11,y+89,3.0,
    {0.06,0.06,0.06,1},ox,oy,sc)
  finalText("MONEY",x+11,y+98,2.4,
    {0.36,0.36,0.32,1},ox,oy,sc)
  finalText(("$%d"):format(tonumber(save.money) or 0),x+29,y+98,2.8,
    {0.06,0.06,0.06,1},ox,oy,sc,"right",16)

  local rx=x+63
  finalText("POKéDEX",rx,y+29,2.5,{0.36,0.36,0.32,1},ox,oy,sc)
  finalText(tostring(caught).." CAUGHT",rx,y+37,3.1,
    {0.06,0.06,0.06,1},ox,oy,sc)
  finalText("PLAY TIME",rx,y+49,2.5,{0.36,0.36,0.32,1},ox,oy,sc)
  finalText(("%d:%02d"):format(math.floor(t/3600),math.floor(t/60)%60),
    rx,y+57,3.1,{0.06,0.06,0.06,1},ox,oy,sc)
  finalText("BADGES",rx,y+69,2.5,{0.36,0.36,0.32,1},ox,oy,sc)
  finalText(tostring(badgeCount).." / 8",rx,y+77,3.1,
    {0.06,0.06,0.06,1},ox,oy,sc)

  local defs=(Badges and game and type(Badges.list)=="function")
      and Badges.list(game.data) or {}
  if card.badges and card.faces and Badges then
    for i=1,math.min(8,#defs) do
      local col=(i-1)%4
      local row=math.floor((i-1)/4)
      local bx=x+62+col*13
      local by=y+84+row*10
      local owned=save.inventory and save.inventory[Badges.itemFor(defs[i])]
      local sheet=owned and card.badges or card.faces
      local q=sheet and sheet.quads and sheet.quads[i-1]
      if q then
        g.push("all"); g.origin()
        g.setColor(1,1,1,owned and 1 or 0.38)
        g.draw(sheet.img,q,
          math.floor(ox+bx*sc),math.floor(oy+by*sc),0,0.48*sc,0.48*sc)
        g.pop()
      end
    end
  end

  finalText("B: BACK",x+8,y+h-6,2.25,
    {0.32,0.32,0.29,1},ox,oy,sc)
end

-- Keep the Gen 1 level-up card as a dedicated battle overlay. It is not an
-- overworld hanging menu, but use the proven final-window font renderer rather
-- than native 8x8 EngineFont text.

function GoldCompat.drawGen2TrainerCardHanging(card)
  local save=card and card.save or {}
  local player=save.player or {}
  local page=card and card.page or 1

  local x,y,w,h=30,12,126,120
  local ox,oy,sc=gen1HangingFrame(x,y,w,h,
    page==1 and "TRAINER CARD"
      or (page==2 and "JOHTO BADGES" or "KANTO BADGES"))
  local g=love.graphics

  g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
  g.setColor(0.12,0.12,0.11,1)
  roundedRect("fill",x+5,y+20,47,88,3)
  roundedRect("fill",x+56,y+20,65,88,3)
  g.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+7,y+22,43,84,2)
  roundedRect("fill",x+58,y+22,61,84,2)
  g.setColor(0.76,0.62,0.30,1)
  roundedRect("line",x+8,y+23,41,82,2)
  roundedRect("line",x+59,y+23,59,82,2)
  g.pop()

  local canvas=GoldCompat.drawNativeTrainerCanvas(card)
  if canvas then
    g.push("all")
    g.origin()
    g.setColor(1,1,1,1)
    if page==1 then
      local q=g.newQuad(112,8,40,56,160,144)
      local shader=GoldCompat.trainerPortraitShader()
      if shader then g.setShader(shader) end
      g.draw(canvas,q,ox+(x+10)*sc,oy+(y+27)*sc,0,0.62*sc,0.62*sc)
      g.setShader()
    else
      local q=g.newQuad(8,76,144,64,160,144)
      g.draw(canvas,q,ox+(x+61)*sc,oy+(y+37)*sc,0,0.39*sc,0.39*sc)
    end
    g.pop()
  end

  if page==1 then
    finalText(tostring(player.name or "GOLD"),x+11,y+72,4.0,
      {0.06,0.06,0.06,1},ox,oy,sc)
    finalText("TRAINER ID",x+11,y+82,2.4,
      {0.36,0.36,0.32,1},ox,oy,sc)
    finalText(("%05d"):format(tonumber(player.id) or 0),x+11,y+89,3.0,
      {0.06,0.06,0.06,1},ox,oy,sc)
    finalText("MONEY",x+11,y+98,2.4,
      {0.36,0.36,0.32,1},ox,oy,sc)
    finalText(("¥%d"):format(tonumber(player.money) or 0),x+28,y+98,2.8,
      {0.06,0.06,0.06,1},ox,oy,sc,"right",17)

    local caught=card.caughtCount and card:caughtCount() or 0
    local seen=GoldCompat.countTruthy((save.pokedex or {}).seen)
    local t=save.playTime or {}
    local badges=GoldCompat.countTruthy(player.badges)
    local owned=GoldCompat.trainerOwnedCount(save)
    local trades=GoldCompat.countTruthy(save.tradeFlags)
    local league=(save.hallOfFame and tonumber(save.hallOfFame.count)) or 0
    local rx=x+63

    finalText("POKéDEX",rx,y+29,2.5,{0.36,0.36,0.32,1},ox,oy,sc)
    finalText(("%d SEEN / %d CAUGHT"):format(seen,caught),
      rx,y+37,2.6,{0.06,0.06,0.06,1},ox,oy,sc,"left",51)
    finalText("PLAY TIME",rx,y+49,2.5,{0.36,0.36,0.32,1},ox,oy,sc)
    finalText(("%d:%02d"):format(t.hours or 0,t.minutes or 0),
      rx,y+57,3.1,{0.06,0.06,0.06,1},ox,oy,sc)
    finalText("JOHTO BADGES",rx,y+69,2.4,{0.36,0.36,0.32,1},ox,oy,sc)
    finalText(("%d / 8"):format(badges),rx,y+77,3.1,
      {0.06,0.06,0.06,1},ox,oy,sc)
    -- Career stats get their own compact block with a safe bottom inset.
    -- The previous y+103 LEAGUE line sat directly on the inner card border.
    finalText("OWNED "..tostring(owned),rx,y+85,2.35,
      {0.28,0.28,0.25,1},ox,oy,sc)
    finalText("TRADES "..tostring(trades),rx,y+92,2.35,
      {0.28,0.28,0.25,1},ox,oy,sc)
    finalText("LEAGUE "..tostring(league),rx,y+99,2.35,
      {0.28,0.28,0.25,1},ox,oy,sc)
  else
    local ownedBadges=page==2 and (player.badges or {}) or (player.kantoBadges or {})
    local count=GoldCompat.countTruthy(ownedBadges)
    finalText(("%d / 8 EARNED"):format(count),x+64,y+29,3.0,
      {0.06,0.06,0.06,1},ox,oy,sc)
    finalText("LEFT / RIGHT: PAGE",x+64,y+103,2.3,
      {0.30,0.30,0.27,1},ox,oy,sc)
  end

  finalText("B: BACK",x+8,y+h-6,2.25,
    {0.32,0.32,0.29,1},ox,oy,sc)
end

function GoldCompat.drawGen1LevelUpBox(box)
  local mon=box and box.mon
  local game=box and box.game
  if not (featureEnabled("revampedLevelUpUI")
      or GoldCompat.strictBattleUiForGame(game)) then return false end
  if not (mon and game and mon.stats) then return false end

  local level=tonumber(mon.level) or 1
  local def=game.data and game.data.pokemon and game.data.pokemon[mon.species]
  local old={}
  local Stats=GoldCompat.engineModule("src.pokemon.Stats")
  if Stats and type(Stats.calc)=="function" and def then
    local ok,v=pcall(Stats.calc,def,math.max(1,level-1),
      mon.dvs or {},mon.statExp or {})
    if ok and type(v)=="table" then old=v end
  end

  local ox,oy,sc=finalCanvas()
  local g=love.graphics
  local x,y,w,h=52,7,58,100

  -- The normal UI Box Size setting is allowed to overscan the 160x144 canvas
  -- slightly for large hanging menus. The level-up card is much taller and
  -- should never inherit that overscan: clamp only this overlay to the real
  -- display bounds while preserving its centered logical placement.
  local sw,sh=love.graphics.getDimensions()
  local safeMargin=6
  local maxCardScale=math.min(
    (sw-safeMargin*2)/w,
    (sh-safeMargin*2)/h
  )
  if sc>maxCardScale then
    sc=maxCardScale
    ox=(sw-160*sc)*0.5
    oy=(sh-144*sc)*0.5
  end

  -- If the centered 160x144 canvas would still place the tall card outside the
  -- screen, shift the canvas just enough to keep the card fully visible.
  local cardTop=oy+y*sc
  local cardBottom=oy+(y+h)*sc
  if cardTop<safeMargin then
    oy=oy+(safeMargin-cardTop)
  end
  if cardBottom>sh-safeMargin then
    oy=oy-((cardBottom)-(sh-safeMargin))
  end

  g.push("all"); g.translate(ox,oy); g.scale(sc,sc)
  g.setColor(0.04,0.04,0.04,0.34)
  roundedRect("fill",x+2,y+2,w,h,4)
  g.setColor(0.075,0.085,0.08,0.98)
  roundedRect("fill",x,y,w,h,4)
  g.setColor(0.36,0.39,0.36,1)
  roundedRect("line",x,y,w,h,4)
  g.setColor(0.79,0.64,0.20,1)
  g.rectangle("fill",x+5,y+5,w-10,1.2)
  g.setColor(0.14,0.15,0.14,1)
  roundedRect("fill",x+6,y+19,w-12,12,2)
  g.pop()

  local white={0.98,0.98,0.95,1}
  local muted={0.70,0.72,0.68,1}
  finalText("LEVEL UP!",x+7,y+9,3.8,white,ox,oy,sc)
  finalText("Lv. "..tostring(level),x+w-20,y+9,2.8,
    {0.89,0.79,0.42,1},ox,oy,sc,"right",14)

  local name=mon.nickname or (def and def.name) or tostring(mon.species)
  finalText(name,x+9,y+22,2.9,white,ox,oy,sc,"left",w-18)

  local rows={{"HP","hp"},{"ATTACK","attack"},{"DEFENSE","defense"},
              {"SP. ATK","special"},{"SP. DEF","special"},{"SPEED","speed"}}
  for i,row in ipairs(rows) do
    local key=row[2]
    local value=tonumber(mon.stats[key]) or 0
    local prior=tonumber(old[key]) or value
    local d=value-prior
    local yy=y+38+(i-1)*8
    finalText(row[1],x+8,yy,2.25,muted,ox,oy,sc)
    finalText(tostring(value),x+w-20,yy,2.7,white,
      ox,oy,sc,"right",10)
    finalText((d>=0 and "+" or "")..tostring(d),x+w-8,yy,2.15,
      d>0 and {0.34,0.85,0.49,1} or muted,
      ox,oy,sc,"right",7)
  end
  finalText("A  CONTINUE",x+w-27,y+h-8,1.9,muted,
    ox,oy,sc,"right",23)
  return true
end

function GoldCompat.installGen1ModernScreens()
  if GoldCompat.generation~="gen1" or GoldCompat.gen1ModernScreensInstalled then return end

  local okOptions,OptionsMenu=pcall(require,"src.ui.OptionsMenu")
  if okOptions and type(OptionsMenu)=="table"
      and not OptionsMenu.__gen3uiModernPatched then
    OptionsMenu.__gen3uiModernPatched=true
    OptionsMenu.__gen3uiOriginalDraw=OptionsMenu.draw
    -- FOUND: this whole .update patch was dead code -- __gen3uiOriginalUpdate
    -- was checked here but never actually ASSIGNED anywhere (contrast with
    -- __gen3uiOriginalDraw right above, and with SummaryMenu/PokedexMenu
    -- elsewhere in this file, which do assign their __gen3uiOriginalUpdate
    -- before this same style of check), so `type(nil)=="function"` was always
    -- false and OptionsMenu.update was never actually replaced. On top of
    -- that, the condition inside used goldScreenEnabled (hardcoded gen2-only
    -- by design -- see its definition) instead of screenFeatureEnabled, so
    -- even with the missing assignment fixed it would never have fired for
    -- Gen 1 anyway. This mattered beyond cosmetics: __gen3uiHangingOptions is
    -- read by GoldCompat.supportedOverworldMenuState, so a newly-pushed
    -- Options state was never recognized as a supported hanging menu until
    -- its first draw() call, one frame later than intended.
    OptionsMenu.__gen3uiOriginalUpdate=OptionsMenu.update
    if type(OptionsMenu.__gen3uiOriginalUpdate)=="function" then
      OptionsMenu.update=function(self,...)
        if screenFeatureEnabled("revampedOptionsUI") then
          self.isOpaque=false
          self.__gen3uiHangingOptions=true
        end
        return callOriginal(OptionsMenu.__gen3uiOriginalUpdate,self,...)
      end
    end

    -- Unconditional class-level default, matching how every Gen 2 equivalent
    -- in installCoreMenuUI does this (OptionsMenu.isOpaque=false etc. there).
    -- Harmless when the feature is off (native draw still paints its own
    -- full background), and closes the gap where the very first frame a
    -- state exists -- before update() or draw() has run for it even once --
    -- could otherwise still read the old default opaque flag.
    OptionsMenu.isOpaque=false

    OptionsMenu.draw=function(self,...)
      if screenFeatureEnabled("revampedOptionsUI") then
        self.__gen3uiHangingOptions=true
        self.isOpaque=false
        State.activeGen1Options=self
        -- Run native draw with a zero-size scissor instead of skipping it
        -- outright: some engine menu draws also advance per-frame
        -- navigation/pagination bookkeeping (see runDrawInvisible's own
        -- comment), and never calling native draw at all risks starving
        -- that bookkeeping -- exactly the class of bug already found and
        -- fixed for the Gen 2 battle HUD erase (drawPanel/drawStatsBox).
        -- This guarantees zero native pixels reach the frame either way.
        if type(OptionsMenu.__gen3uiOriginalDraw)=="function" then
          return runDrawInvisible(OptionsMenu.__gen3uiOriginalDraw,self,...)
        end
        return
      end
      State.activeGen1Options=nil
      return callOriginal(OptionsMenu.__gen3uiOriginalDraw,self,...)
    end
  end

  local okManager,ManagerState=pcall(require,"src.mods.ManagerState")
  if okManager and type(ManagerState)=="table"
      and not ManagerState.__gen3uiGoldVisualPatched then
    ManagerState.__gen3uiGoldVisualPatched=true
    ManagerState.__gen3uiOriginalDraw=ManagerState.draw
    -- Unconditional class-level default -- see the matching comment on
    -- OptionsMenu.isOpaque above.
    ManagerState.isOpaque=false
    ManagerState.draw=function(self,...)
      if screenFeatureEnabled("revampedModsUI") then
        self.__gen3uiHangingMods=true
        self.isOpaque=false
        State.activeGen1Mods=self
        if type(ManagerState.__gen3uiOriginalDraw)=="function" then
          return runDrawInvisible(ManagerState.__gen3uiOriginalDraw,self,...)
        end
        return
      end
      State.activeGen1Mods=nil
      return callOriginal(ManagerState.__gen3uiOriginalDraw,self,...)
    end
  end

  local okTrainer,TrainerCard=pcall(require,"src.ui.TrainerCard")
  if okTrainer and type(TrainerCard)=="table"
      and not TrainerCard.__gen3uiModernPatched then
    TrainerCard.__gen3uiModernPatched=true
    TrainerCard.__gen3uiOriginalDraw=TrainerCard.draw
    -- Same two bugs as OptionsMenu above: __gen3uiOriginalUpdate was never
    -- assigned (dead .update patch) and the gate used goldScreenEnabled
    -- (gen2-only by design) instead of screenFeatureEnabled.
    TrainerCard.__gen3uiOriginalUpdate=TrainerCard.update
    if type(TrainerCard.__gen3uiOriginalUpdate)=="function" then
      TrainerCard.update=function(self,...)
        if screenFeatureEnabled("revampedTrainerCardUI") then
          self.isOpaque=false
          self.__gen3uiHangingTrainer=true
        end
        return callOriginal(TrainerCard.__gen3uiOriginalUpdate,self,...)
      end
    end

    -- Unconditional class-level default -- see the matching comment on
    -- OptionsMenu.isOpaque above.
    TrainerCard.isOpaque=false

    TrainerCard.draw=function(self,...)
      if screenFeatureEnabled("revampedTrainerCardUI") then
        self.__gen3uiHangingTrainer=true
        self.isOpaque=false
        State.activeGen1TrainerCard=self
        if type(TrainerCard.__gen3uiOriginalDraw)=="function" then
          return runDrawInvisible(TrainerCard.__gen3uiOriginalDraw,self,...)
        end
        return
      end
      State.activeGen1TrainerCard=nil
      return callOriginal(TrainerCard.__gen3uiOriginalDraw,self,...)
    end
  end

  local okBattle,BattleState=pcall(require,"src.battle.BattleState")
  local StatBox=okBattle and BattleState and BattleState.StatBox
  if StatBox and not StatBox.__gen3uiModernPatched then
    StatBox.__gen3uiModernPatched=true
    StatBox.__gen3uiOriginalDraw=StatBox.draw
    StatBox.__gen3uiOriginalNew=StatBox.new

    -- StatBox is a pushed battle state. Its native draw happens on the GB
    -- battle canvas, while our modern card belongs in the late HUD pass.
    -- Mark ownership here and render it after the battlefield instead.
    StatBox.draw=function(self,...)
      -- HARD HIDE must remain usable, not merely blank. Even when the separate
      -- LEVEL-UP UI option is off, claim this pushed battle state and render
      -- the modern stat card in the late HUD pass so no native pixels leak and
      -- no level-up information is lost.
      if screenFeatureEnabled("revampedLevelUpUI")
          or GoldCompat.strictBattleUiForGame(self.game) then
        self.__gen3uiLevelUpBox=true
        State.activeGen1LevelUpBox=self
        return
      end
      self.__gen3uiLevelUpBox=nil
      if State.activeGen1LevelUpBox==self then
        State.activeGen1LevelUpBox=nil
      end
      return callOriginal(StatBox.__gen3uiOriginalDraw,self,...)
    end

    -- Instance-level belt-and-suspenders protection for engines/mods that
    -- capture StatBox.draw during construction.
    if type(StatBox.__gen3uiOriginalNew)=="function" then
      StatBox.new=function(...)
        local box=StatBox.__gen3uiOriginalNew(...)
        box.__gen3uiLevelUpBox=true
        return box
      end
    end
  end

  -- Gen 1's real Pokédex CONTENTS list (src/ui/PokedexMenu.lua) is a bespoke
  -- class -- it is never built via ListMenu.new, so the shared
  -- ListMenu.draw/Menu.new "POKéDEX title" / "DATA CRY AREA QUIT" detection
  -- installed in installOverworldUI's DexUI plumbing never actually sees it,
  -- and the DexUI.entry wrap already sitting on the shared src.ui.DexEntryMenu
  -- class (installOverworldUI, right before BagMenu setup) has been dead code
  -- until now: nothing on Gen 1 ever called DexEntryMenu.new because nothing
  -- ever pushed a styled Pokédex CONTENTS screen for the player to press A
  -- from. Confirmed field-for-field against the real class: self.items is an
  -- array whose position n IS the national dex number n (built via
  -- `for n=1,math.min(dexSize,maxSeen) do local def=byDex[n] ...`), and
  -- self.index is a 1-based index into that same array -- exactly the shape
  -- DexUI.draw already expects from Gen 2 (it keys its own species lookup by
  -- def.dex and reads state.items/state.index directly), so the real
  -- instance can be handed to DexUI.draw completely unmodified.
  local okDex1,PokedexMenu1=pcall(require,"src.ui.PokedexMenu")
  if okDex1 and type(PokedexMenu1)=="table"
      and not PokedexMenu1.__gen3uiModernPatched then
    PokedexMenu1.__gen3uiModernPatched=true
    PokedexMenu1.__gen3uiOriginalNew=PokedexMenu1.new
    PokedexMenu1.__gen3uiOriginalDraw=PokedexMenu1.draw
    PokedexMenu1.__gen3uiOriginalOnChoose=PokedexMenu1.onChoose

    -- Unconditional class-level default, matching OptionsMenu/ManagerState/
    -- TrainerCard above: harmless when the feature is off (native draw still
    -- paints its own full 160x144 background), and closes the gap where the
    -- very first frame a state exists could otherwise still read the old
    -- default opaque flag.
    PokedexMenu1.isOpaque=false

    -- Mark __gen3uiPokedex at construction, not first draw. This is the same
    -- one-frame-late bug already found and fixed for OptionsMenu's
    -- __gen3uiHangingOptions: GoldCompat.supportedOverworldMenuState reads
    -- this flag, and a state not yet recognized as "supported" for even one
    -- frame can cause clearStaleOverworldOwnership to blow away unrelated
    -- START/Bag overlay state on the way in.
    PokedexMenu1.new=function(...)
      local self=PokedexMenu1.__gen3uiOriginalNew(...)
      if self then
        self.__gen3uiPokedex=true
        self.isOpaque=false
      end
      return self
    end

    PokedexMenu1.draw=function(self,...)
      if not screenFeatureEnabled("revampedPokedex")
          or self.__gen3uiPokedexRenderFailed then
        DexUI.active=nil
        return callOriginal(PokedexMenu1.__gen3uiOriginalDraw,self,...)
      end
      self.__gen3uiPokedex=true
      self.isOpaque=false
      DexUI.active=self
    end

    -- chooseEntry (src/ui/PokedexMenu.lua) pushes a plain Menu instance for
    -- the DATA/CRY/AREA/[PRNT]/QUIT action card, then immediately overwrites
    -- THAT INSTANCE's own .draw field with a private local (side.draw =
    -- drawSideMenu) -- an instance field always wins over a class method in
    -- Lua, so the shared Menu.draw patch elsewhere in this mod (which already
    -- recognizes this exact card by its DATA/CRY/AREA/QUIT labels and would
    -- otherwise route it through DexUI.action) never actually runs for it.
    -- Confirmed by reading chooseEntry directly: without this, the native
    -- card kept drawing on top of/behind our own every time. Re-intercept the
    -- instance the moment native code hands it back to us.
    PokedexMenu1.onChoose=function(item,dexList)
      PokedexMenu1.__gen3uiOriginalOnChoose(item,dexList)
      if not screenFeatureEnabled("revampedPokedex") then return end

      local stack=dexList and dexList.game and dexList.game.stack
      local top=stack and ((stack.top and stack:top())
        or (stack.states and stack.states[#stack.states]))

      if top and top~=dexList and type(top.draw)=="function"
          and not top.__gen3uiPokedexActionWrapped then
        top.__gen3uiPokedexActionWrapped=true
        top.__gen3uiPokedexAction=true
        top.isOpaque=false
        local nativeSideDraw=top.draw
        top.draw=function(self,...)
          if screenFeatureEnabled("revampedPokedex")
              and not self.__gen3uiPokedexActionRenderFailed then
            DexUI.action=self
            return
          end
          return callOriginal(nativeSideDraw,self,...)
        end
      end
    end
  end

  GoldCompat.gen1ModernScreensInstalled=true
end

function GoldCompat.gen2MenuFadeSuppressed()
  if GoldCompat.generation~="gen2" then return false end
  -- Gen1Recomp's newer Gen2MenuFade emulates long white cartridge reloads.
  -- Those pixels are inappropriate when a final-layer replacement owns the
  -- destination menu, but native fades remain untouched when its UI is off.
  return featureEnabled("revampedOverworldMenus")
    or featureEnabled("revampedPokemonMenu")
    or featureEnabled("revampedPokedex")
    or featureEnabled("revampedPokegearUI")
    or featureEnabled("revampedTrainerCardUI")
    or featureEnabled("revampedOptionsUI")
end

function GoldCompat.installGen2MenuFadeCompat()
  if GoldCompat.generation~="gen2" then return end
  local ok,MenuFade=pcall(require,"src.ui.gen2.MenuFade")
  if not (ok and type(MenuFade)=="table") or MenuFade.__gen3uiFadePatched then
    return
  end
  MenuFade.__gen3uiFadePatched=true
  local oldUpdate=MenuFade.update
  local oldDraw=MenuFade.draw
  local oldWide=MenuFade.drawWidescreen

  -- Preserve MenuFade's underlying-state compositor while forcing only its
  -- white veil transparent. This avoids a blank widescreen frame.
  local function withoutWhite(method,self,...)
    local ownLevel=rawget(self,"level")
    self.level=function() return 0 end
    local results={pcall(method,self,...)}
    self.level=ownLevel
    if not results[1] then error(results[2]) end
    return unpack(results,2)
  end

  if type(oldDraw)=="function" then
    MenuFade.draw=function(self,...)
      if GoldCompat.gen2MenuFadeSuppressed() then
        return withoutWhite(oldDraw,self,...)
      end
      return oldDraw(self,...)
    end
  end
  if type(oldWide)=="function" then
    MenuFade.drawWidescreen=function(self,...)
      if GoldCompat.gen2MenuFadeSuppressed() then
        return withoutWhite(oldWide,self,...)
      end
      return oldWide(self,...)
    end
  end
  if type(oldUpdate)=="function" then
    MenuFade.update=function(self,...)
      if GoldCompat.gen2MenuFadeSuppressed() then
        -- Complete on the next native update: pop/onDone semantics stay exact,
        -- but the 11-31 frame white hold no longer stalls custom menu changes.
        self.frame=math.max(tonumber(self.frame) or 1,tonumber(self.total) or 1)
      end
      return oldUpdate(self,...)
    end
  end
end

function GoldCompat.installCoreMenuUI()
  if GoldCompat.generation~="gen2" or GoldCompat.coreMenusInstalled then return end

  local okStart,StartMenu=pcall(require,"src.ui.gen2.StartMenu")
  if okStart and type(StartMenu)=="table" and not StartMenu.__gen3uiVisualPatched then
    StartMenu.__gen3uiVisualPatched=true
    StartMenu.__gen3uiOriginalDraw=StartMenu.draw

    -- Same ownership model as Gen 1 START: suppress native Gold chrome, keep
    -- the state/input fully native, and render the mature final-window START UI
    -- later in render.hud over the still-visible overworld.
    StartMenu.draw=function(self)
      -- Match the ownership contract used by the Gen 1 Start menu so
      -- clearStaleOverworldOwnership() recognizes this as a valid active menu.
      self.__gen3uiStart=true
      GoldCompat.prepareGoldStartMenu(self)
      return
    end
  end

  local okSave,SaveMenu=pcall(require,"src.ui.gen2.SaveMenu")
  if okSave and type(SaveMenu)=="table" and not SaveMenu.__gen3uiVisualPatched then
    SaveMenu.__gen3uiVisualPatched=true
    SaveMenu.__gen3uiOriginalNew=SaveMenu.new
    SaveMenu.__gen3uiOriginalDraw=SaveMenu.draw
    SaveMenu.__gen3uiOriginalDrawWidescreen=SaveMenu.drawWidescreen
    SaveMenu.__gen3uiOriginalDrawsWidescreen=SaveMenu.drawsWidescreen
    SaveMenu.__gen3uiOriginalWantsFillScale=SaveMenu.wantsFillScale
    SaveMenu.__gen3uiOriginalIsOpaque=SaveMenu.isOpaque

    SaveMenu.drawsWidescreen=function(self,...)
      if goldScreenEnabled("revampedSaveUI") then return false end
      return callOriginal(SaveMenu.__gen3uiOriginalDrawsWidescreen,self,...)
    end
    SaveMenu.wantsFillScale=function(self,...)
      if goldScreenEnabled("revampedSaveUI") then return false end
      return callOriginal(SaveMenu.__gen3uiOriginalWantsFillScale,self,...)
    end
    SaveMenu.new=function(...)
      local self=SaveMenu.__gen3uiOriginalNew(...)
      if goldScreenEnabled("revampedSaveUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="save"
      else
        self.isOpaque=SaveMenu.__gen3uiOriginalIsOpaque
        self.__gen3uiGoldOverlayKind=nil
      end
      return self
    end
    SaveMenu.draw=function(self,...)
      if goldScreenEnabled("revampedSaveUI") then
        self.__gen3uiGoldOverlayKind="save"
        if type(SaveMenu.__gen3uiOriginalDraw)=="function" then
          return runDrawInvisible(SaveMenu.__gen3uiOriginalDraw,self,...)
        end
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(SaveMenu.__gen3uiOriginalDraw,self,...)
    end
    SaveMenu.drawWidescreen=function(self,...)
      if goldScreenEnabled("revampedSaveUI") then
        self.__gen3uiGoldOverlayKind="save"
        if type(SaveMenu.__gen3uiOriginalDrawWidescreen)=="function" then
          return runDrawInvisible(SaveMenu.__gen3uiOriginalDrawWidescreen,self,...)
        end
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(SaveMenu.__gen3uiOriginalDrawWidescreen,self,...)
    end
  end

  local okOptions,OptionsMenu=pcall(require,"src.ui.gen2.OptionsMenu")
  if okOptions and type(OptionsMenu)=="table"
      and not OptionsMenu.__gen3uiVisualPatched then
    OptionsMenu.__gen3uiVisualPatched=true
    OptionsMenu.__gen3uiOriginalNew=OptionsMenu.new
    OptionsMenu.__gen3uiOriginalDraw=OptionsMenu.draw
    OptionsMenu.__gen3uiOriginalDrawWidescreen=OptionsMenu.drawWidescreen
    OptionsMenu.__gen3uiOriginalDrawsWidescreen=OptionsMenu.drawsWidescreen
    OptionsMenu.__gen3uiOriginalWantsFillScale=OptionsMenu.wantsFillScale
    OptionsMenu.__gen3uiOriginalOpaque=OptionsMenu.isOpaque

    OptionsMenu.isOpaque=false
    OptionsMenu.drawsWidescreen=function() return false end
    OptionsMenu.wantsFillScale=function() return false end

    if type(OptionsMenu.new)=="function" then
      OptionsMenu.new=function(...)
        local self=OptionsMenu.__gen3uiOriginalNew(...)
        if goldScreenEnabled("revampedOptionsUI") then
          self.isOpaque=false
          self.__gen3uiGoldOverlayKind="options"
        end
        return self
      end
    end

    OptionsMenu.draw=function(self,...)
      if goldScreenEnabled("revampedOptionsUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="options"
        if type(OptionsMenu.__gen3uiOriginalDraw)=="function" then
          return runDrawInvisible(OptionsMenu.__gen3uiOriginalDraw,self,...)
        end
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(OptionsMenu.__gen3uiOriginalDraw,self,...)
    end

    OptionsMenu.drawWidescreen=function(self,...)
      if goldScreenEnabled("revampedOptionsUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="options"
        if type(OptionsMenu.__gen3uiOriginalDrawWidescreen)=="function" then
          return runDrawInvisible(
            OptionsMenu.__gen3uiOriginalDrawWidescreen,self,...)
        end
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(
        OptionsMenu.__gen3uiOriginalDrawWidescreen,self,...)
    end
  end

  local okTrainer,TrainerCard=pcall(require,"src.ui.gen2.TrainerCard")
  if okTrainer and type(TrainerCard)=="table"
      and not TrainerCard.__gen3uiVisualPatched then
    TrainerCard.__gen3uiVisualPatched=true
    TrainerCard.__gen3uiOriginalNew=TrainerCard.new
    TrainerCard.__gen3uiOriginalDraw=TrainerCard.draw
    TrainerCard.__gen3uiOriginalDrawPanel=TrainerCard.drawPanel
    TrainerCard.__gen3uiOriginalDrawWidescreen=TrainerCard.drawWidescreen
    TrainerCard.__gen3uiOriginalDrawsWidescreen=TrainerCard.drawsWidescreen
    TrainerCard.__gen3uiOriginalWantsFillScale=TrainerCard.wantsFillScale
    TrainerCard.__gen3uiOriginalOpaque=TrainerCard.isOpaque

    TrainerCard.isOpaque=false
    TrainerCard.drawsWidescreen=function() return false end
    TrainerCard.wantsFillScale=function() return false end

    if type(TrainerCard.new)=="function" then
      TrainerCard.new=function(...)
        local self=TrainerCard.__gen3uiOriginalNew(...)
        if goldScreenEnabled("revampedTrainerCardUI") then
          self.isOpaque=false
          self.__gen3uiGoldOverlayKind="trainer"
        end
        return self
      end
    end

    TrainerCard.draw=function(self,...)
      if goldScreenEnabled("revampedTrainerCardUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="trainer"
        if type(TrainerCard.__gen3uiOriginalDraw)=="function" then
          return runDrawInvisible(TrainerCard.__gen3uiOriginalDraw,self,...)
        end
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(TrainerCard.__gen3uiOriginalDraw,self,...)
    end

    TrainerCard.drawWidescreen=function(self,...)
      if goldScreenEnabled("revampedTrainerCardUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="trainer"
        if type(TrainerCard.__gen3uiOriginalDrawWidescreen)=="function" then
          return runDrawInvisible(
            TrainerCard.__gen3uiOriginalDrawWidescreen,self,...)
        end
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(
        TrainerCard.__gen3uiOriginalDrawWidescreen,self,...)
    end
  end

  -- ManagerState stays completely native for navigation/actions. Gold now
  -- routes it through the same service-overlay seam as Pack/Mart/Save.
  local okManager,ManagerState=pcall(require,"src.mods.ManagerState")
  if okManager and type(ManagerState)=="table"
      and not ManagerState.__gen3uiGoldVisualPatched then
    ManagerState.__gen3uiGoldVisualPatched=true
    ManagerState.__gen3uiOriginalNew=ManagerState.new
    ManagerState.__gen3uiOriginalDraw=ManagerState.draw
    ManagerState.__gen3uiOriginalDrawWidescreen=ManagerState.drawWidescreen
    ManagerState.__gen3uiOriginalDrawsWidescreen=ManagerState.drawsWidescreen
    ManagerState.__gen3uiOriginalWantsFillScale=ManagerState.wantsFillScale
    ManagerState.__gen3uiOriginalOpaque=ManagerState.isOpaque

    ManagerState.isOpaque=false
    ManagerState.drawsWidescreen=function() return false end
    ManagerState.wantsFillScale=function() return false end

    if type(ManagerState.new)=="function" then
      ManagerState.new=function(...)
        local self=ManagerState.__gen3uiOriginalNew(...)
        if goldScreenEnabled("revampedModsUI") then
          self.isOpaque=false
          self.__gen3uiGoldOverlayKind="mods"
        end
        return self
      end
    end

    ManagerState.draw=function(self,...)
      if goldScreenEnabled("revampedModsUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="mods"
        if type(ManagerState.__gen3uiOriginalDraw)=="function" then
          return runDrawInvisible(ManagerState.__gen3uiOriginalDraw,self,...)
        end
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(ManagerState.__gen3uiOriginalDraw,self,...)
    end

    ManagerState.drawWidescreen=function(self,...)
      if goldScreenEnabled("revampedModsUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="mods"
        if type(ManagerState.__gen3uiOriginalDrawWidescreen)=="function" then
          return runDrawInvisible(
            ManagerState.__gen3uiOriginalDrawWidescreen,self,...)
        end
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(
        ManagerState.__gen3uiOriginalDrawWidescreen,self,...)
    end
  end

  local okParty,PartyMenu=pcall(require,"src.ui.gen2.PartyMenu")
  if okParty and type(PartyMenu)=="table" and not PartyMenu.__gen3uiVisualPatched then
    PartyMenu.__gen3uiVisualPatched=true
    PartyMenu.__gen3uiOriginalDrawWidescreen=PartyMenu.drawWidescreen
    PartyMenu.__gen3uiOriginalWantsFillScale=PartyMenu.wantsFillScale
    PartyMenu.__gen3uiOriginalPanelSize=PartyMenu.panelSize
    PartyMenu.__gen3uiOriginalBattlePanelScale=PartyMenu.battlePanelScale

    -- A transparent PartyMenu opened DURING a battle is not an overworld
    -- screen. Game2 chooses only one widescreen owner per frame; because this
    -- PartyMenu sits on top, simply making it transparent means BattleState's
    -- own drawWidescreen() is skipped completely. v2.1.31 tried to compensate
    -- by forcing bgMode()=="world" for a full-frame renderer, but that only
    -- tells Game2 to draw the literal overworld map -- exactly the regression
    -- now visible when switching Pokemon in a CBE battle.
    --
    -- Keep the PartyMenu as the TOP widescreen owner (so Game2 does not enter
    -- its duplicate centered-stack path), but proxy the battle surface through
    -- it exactly once: first ask the live underlying BattleState to render its
    -- real widescreen surface, then draw this mod's hanging Party deck over it.
    -- This is deliberately provider-agnostic. Vanilla, CBE, Stadium or any
    -- future battle-environment renderer stays authoritative through the same
    -- BattleState.drawWidescreen seam it already owns; this mod never draws an
    -- overworld substitute and never snapshots/freezes the battle.
    local function battleBelowParty(self)
      local battle=battleStateInStack(self and self.game)
      if battle and battle~=self then return battle end
      return nil
    end

    PartyMenu.drawWidescreen=function(self,winW,winH)
      local battle=battleBelowParty(self)
      if battle and type(battle.drawWidescreen)=="function" then
        local ok,err=pcall(battle.drawWidescreen,battle,winW,winH)
        if not ok and GoldCompat.mod and GoldCompat.mod.log then
          pcall(GoldCompat.mod.log,"warn",
            "Gen 3 UI: battle-surface proxy failed behind Gen 2 Party: "..
            tostring(err))
        end
      end
      return GoldCompat.drawGoldPartyMenu(self,winW,winH)
    end

    -- Match the underlying battle's presentation scale/geometry while Party is
    -- acting as the widescreen proxy. Outside battle, retain PartyMenu's native
    -- full-screen fit so ordinary START-menu Party still hangs over the map.
    PartyMenu.wantsFillScale=function(self,...)
      local battle=battleBelowParty(self)
      if battle and type(battle.wantsFillScale)=="function" then
        local ok,value=pcall(battle.wantsFillScale,battle,...)
        if ok and value~=nil then return value end
      end
      if type(PartyMenu.__gen3uiOriginalWantsFillScale)=="function" then
        return PartyMenu.__gen3uiOriginalWantsFillScale(self,...)
      end
      return true
    end

    PartyMenu.panelSize=function(self,...)
      local battle=battleBelowParty(self)
      if battle and type(battle.panelSize)=="function" then
        local ok,w,h=pcall(battle.panelSize,battle,...)
        if ok and w and h then return w,h end
      end
      if type(PartyMenu.__gen3uiOriginalPanelSize)=="function" then
        return PartyMenu.__gen3uiOriginalPanelSize(self,...)
      end
      return 160,144
    end

    PartyMenu.battlePanelScale=function(self,winW,winH)
      local battle=battleBelowParty(self)
      if battle and type(battle.battlePanelScale)=="function" then
        local ok,value=pcall(battle.battlePanelScale,battle,winW,winH)
        if ok then return value end
      end
      if type(PartyMenu.__gen3uiOriginalBattlePanelScale)=="function" then
        return PartyMenu.__gen3uiOriginalBattlePanelScale(self,winW,winH)
      end
      return nil
    end

    -- Real src/ui/gen2/PartyMenu.lua also hardcodes `PartyMenu.isOpaque =
    -- true` at the module level -- same fix, same reasoning as Gen 1's
    -- PartyMenu above (see installOverworldUI): drawGoldPartyMenu already
    -- paints no full-canvas backplate of its own, so the only thing keeping
    -- Gen 2's party screen a solid backplate was the engine never being told
    -- it's safe to render the overworld underneath.
    PartyMenu.isOpaque=false

    -- FOUND (v2.1.28): isOpaque=false plus dropping our own backplate fill
    -- (v2.1.27) still isn't enough for Gen 2 -- confirmed by user screenshot
    -- showing a correctly TRANSPARENT card over a solid BLACK screen instead
    -- of the live overworld. Root cause is structural, in the real engine's
    -- own Gen 2 render pipeline (`src/core/Game2.lua:drawScene`), and has no
    -- Gen 1 equivalent: Gen 1's `Game:draw` (src/core/Game.lua) derives its
    -- world-or-not decision generically from `self.stack:visibleBase()` --
    -- once a state is non-opaque, visibleBase naturally walks down to
    -- whatever is actually beneath it, the overworld included, so Gen 1's
    -- isOpaque=false fix alone was already sufficient. Gen 2's pipeline does
    -- NOT do this for a `drawsWidescreen()` state (which PartyMenu natively
    -- is): it only ever calls `self.world:draw()` when `battleSurround(stack)
    -- =="world"`, and `battleSurround` only finds a match by scanning the
    -- stack top-down for a state exposing a `.bgMode()` method -- a contract
    -- that, before this patch, only `BattleState:bgMode()` (src/ui/gen2/
    -- BattleState.lua:320) ever implemented. Outside of battle there was
    -- never any state offering "world" as an option, so `self.world:draw()`
    -- was simply never called for the plain "check your party from the
    -- START menu" case -- vanilla never needed it to be, since native
    -- PartyMenu is opaque and paints its own full backplate regardless.
    --
    -- Fixed by giving Gen 2's PartyMenu the same `bgMode` contract
    -- BattleState uses, reusing the exact extensibility point the engine
    -- already ships rather than touching Game2.lua's internals directly.
    -- When this PartyMenu is stacked over a REAL battle (a mid-battle forced
    -- switch or TM/HM teach), `battleSurround` would otherwise stop at
    -- PartyMenu (it returns on the FIRST state carrying `.bgMode`, top-down)
    -- and never reach BattleState's own real bgMode -- so this delegates
    -- straight through to the actual battle's bgMode/BG_WORLD_DIM in that
    -- case, preserving whatever the user's real BATTLE BG option says
    -- instead of silently overriding it. Only the plain overworld-opened
    -- case (Start menu, Day Care, Trade, Mailbox, TM/HM teach from the Pack
    -- outside battle -- none of which push a real BattleState underneath)
    -- returns "world" unconditionally, which is the one case that actually
    -- needed a fix.
    -- v2.1.33: the menu itself is already a hanging overlay, so the live
    -- overworld must remain untouched all the way to the window edges.  Gen 2
    -- needs bgMode()=="world" to make Game2:drawScene draw that overworld
    -- behind a widescreen state, but Game2:paintBattleSurround then uses
    -- BG_WORLD_DIM to paint four black-alpha bands around the 160x144 panel.
    -- 0.55 was therefore the exact source of the two large dark side borders
    -- visible in the party screenshot.  Keep the world contract, but make its
    -- surround dim zero so the hanging card is composited over an undimmed map.
    PartyMenu.BG_WORLD_DIM=0
    PartyMenu.bgMode=function(self)
      local battle=battleBelowParty(self)
      if battle then
        -- Preserve the REAL battle's surround policy. Most importantly, do not
        -- force "world" merely because an external renderer owns the battle:
        -- in Game2 that string literally means "draw the overworld map now".
        -- The battle surface itself is supplied by the drawWidescreen proxy
        -- above, so CBE/vanilla/other environments remain on screen naturally.
        self.BG_WORLD_DIM=tonumber(battle.BG_WORLD_DIM) or 0.55
        if type(battle.bgMode)=="function" then
          local ok,mode=pcall(battle.bgMode,battle)
          if ok then return mode end
        end
        return nil
      end

      -- Ordinary non-battle Party still needs the explicit Gen 2 "world"
      -- contract introduced in v2.1.28 so the live map is drawn under this
      -- otherwise-widescreen state. Zero dim keeps the hanging-menu surround
      -- clean to the physical window edges (v2.1.33).
      self.BG_WORLD_DIM=0
      return "world"
    end

    -- Gen 2's real TM/HM teach flow (src/ui/gen2/PackMenu.lua:openTeachParty)
    -- pushes THIS class via Screens.push(game,"Gen2PartyMenu",{tmhm=...}),
    -- never Gen 1's src/ui/PartyMenu.lua -- confirmed by reading PackMenu.lua
    -- directly. The entire TM/HM-aware Party integration (State.activeTMParty,
    -- the MoveLearnMenu.new/.draw wraps' canIntegrateMoveLearn check, the
    -- replace-move panel) was wired ONLY onto Gen 1's class, so a Gen 2 TM/HM
    -- item never touched any of it: the target picker rendered as a plain
    -- browse screen with no ABLE/NOT ABLE indication at all, and once a
    -- 4-move Pokémon was chosen, MoveLearnMenu.draw's canIntegrateMoveLearn
    -- check always failed (State.activeTMParty was never set for this
    -- class), falling through to fully NATIVE move-replace rendering
    -- regardless of the revampedPokemonMenu toggle -- confirmed by reading
    -- that wrap: it only ever set State.activeTMParty from Gen 1's own
    -- PartyMenu.new. canIntegrateMoveLearn itself duck-types on `.party`/
    -- `.index` rather than checking a class, so simply pointing
    -- State.activeTMParty at a live Gen 2 instance makes that whole existing
    -- mechanism work for Gen 2 too, with zero changes to it.
    local originalGen2PartyNew=PartyMenu.new
    PartyMenu.new=function(game,opts)
      local party=originalGen2PartyNew(game,opts)
      if party and opts and opts.tmhm then
        party.__gen3uiKeepTMBackground=true
        State.activeTMParty=party
        -- activeTMParty itself is unusable across frames for Gen 2: the
        -- generic Gen 2 branch at the top of renderHudUnderlays nulls it
        -- (along with activeParty etc.) every single frame, since that
        -- variable/mechanism was built for Gen 1's BagMenu flow (which keeps
        -- the real PartyMenu on the stack the whole time, so it only ever
        -- needs to survive one draw). Keep our own dedicated pointer instead,
        -- cleaned up explicitly (see renderHudUnderlays) rather than reset
        -- blindly every frame.
        State.activeGen2TMParty=party
      end
      return party
    end
  end

  -- Gen 2's "forget a move to learn a new one" flow (level-up, TM/HM, move
  -- tutor, evolution) all funnel through the ONE shared Game2:learnMoveOn
  -- (src/core/Game2.lua:544-627), which -- when the mon already has 4 moves
  -- -- pushes the generic, standalone src/ui/gen2/MoveDeleter class with
  -- opts.layout=="forget" (Game2.lua:586-590). That class is ALSO the real
  -- Blackthorn Move Deleter NPC screen and the Ether/Elixir PP-restore
  -- picker (its own header comment: "MoveSelectionScreen and
  -- ChooseMoveToDelete are the same SetUpMoveList box on the cart"), so
  -- unlike Gen 1's dedicated MoveLearnMenu class it can't simply be
  -- retargeted wholesale -- confirmed by reading MoveDeleter.lua and
  -- Game2.lua's pushList() directly. Gen 2 also pops its own party picker
  -- BEFORE calling learnMoveOn (src/ui/gen2/PackMenu.lua:770,
  -- `game.stack:pop()`), unlike Gen 1's BagMenu, which deliberately keeps
  -- PartyMenu on the real stack for exactly this reason (its own comment:
  -- "TM/HM stays up through predef LearnMove", item_effects.asm:2238). That
  -- is why the user saw the plain "MOVE DELETER" box (this mod's existing
  -- generic missing-screen reskin, below) with the live overworld behind it
  -- instead of the Pokémon-menu card Gen 1 already shows: nothing kept the
  -- popped party card around to draw as a background, and nothing routed
  -- the forget-list step through drawPartyMoveReplace the way Gen 1's
  -- MoveLearnMenu wrap does.
  local okGame2,Game2Module=pcall(require,"src.core.Game2")
  if okGame2 and type(Game2Module)=="table"
      and not Game2Module.__gen3uiMoveLearnPatched then
    Game2Module.__gen3uiMoveLearnPatched=true
    local originalLearnMoveOn=Game2Module.learnMoveOn
    Game2Module.learnMoveOn=function(self,mon,moveId,onDone)
      local wantsIntegration=false
      if (goldScreenEnabled("revampedPokemonMenu")
          or GoldCompat.strictBattleUiForGame(self))
          and State.activeGen2TMParty then
        local tmParty=State.activeGen2TMParty.party
          or (self.save and self.save.party) or {}
        local idx=math.max(1,math.min(State.activeGen2TMParty.index or 1,#tmParty))
        wantsIntegration=(tmParty[idx]==mon)
      end
      if wantsIntegration then
        State.activeGen2MoveLearn={
          mon=mon,newMoveId=moveId,party=State.activeGen2TMParty,
        }
      end
      local wrappedDone=function(learned)
        if State.activeGen2MoveLearn and State.activeGen2MoveLearn.mon==mon then
          State.activeGen2MoveLearn=nil
        end
        if onDone then onDone(learned) end
      end
      return originalLearnMoveOn(self,mon,moveId,wrappedDone)
    end
  end

  -- The actual forget-list step. Suppress its own draw (native AND this
  -- mod's generic "move-deleter" box, see the P.renderHud kindFor override
  -- below) while integrated, and let drawGoldPartyMenu's REPLACE MOVE panel
  -- (State.activeGen2MoveDeleter) stand in for it instead -- input/logic
  -- stay entirely native (MoveDeleter:update already owns up/down/A/B).
  local okDeleter,MoveDeleter2=pcall(require,"src.ui.gen2.MoveDeleter")
  if okDeleter and type(MoveDeleter2)=="table"
      and not MoveDeleter2.__gen3uiVisualPatched then
    MoveDeleter2.__gen3uiVisualPatched=true
    local originalDeleterNew=MoveDeleter2.new
    MoveDeleter2.new=function(game,opts)
      local self=originalDeleterNew(game,opts)
      if self.forget and State.activeGen2MoveLearn
          and State.activeGen2MoveLearn.mon==self.mon then
        self.__gen3uiNewMoveId=State.activeGen2MoveLearn.newMoveId
      end
      return self
    end
    local originalDeleterDraw=MoveDeleter2.draw
    MoveDeleter2.draw=function(self,...)
      if self.forget
          and (goldScreenEnabled("revampedPokemonMenu")
            or GoldCompat.strictBattleUiForGame(self.game))
          and State.activeGen2MoveLearn
          and State.activeGen2MoveLearn.mon==self.mon then
        State.activeGen2MoveDeleter=self
        return
      end
      if State.activeGen2MoveDeleter==self then State.activeGen2MoveDeleter=nil end
      return originalDeleterDraw(self,...)
    end
  end

  local okSummary,SummaryMenu=pcall(require,"src.ui.gen2.SummaryMenu")
  if okSummary and type(SummaryMenu)=="table"
      and not SummaryMenu.__gen3uiVisualPatched then
    SummaryMenu.__gen3uiVisualPatched=true
    SummaryMenu.__gen3uiOriginalUpdate=SummaryMenu.update
    SummaryMenu.__gen3uiOriginalDrawWidescreen=SummaryMenu.drawWidescreen

    SummaryMenu.update=function(self,dt)
      local input=self.game and self.game.input
      if not (goldScreenEnabled("revampedPokemonMenu") and input
          and self.mon and not self.mon.isEgg) then
        return SummaryMenu.__gen3uiOriginalUpdate(self,dt)
      end

      if self.__gen3uiMoveManager then
        GoldCompat.updateMoveManager(self,input)
        return
      end

      if self.moveDetail and not self.swapFrom then
        -- Reached via the party field-submenu's native "MOVES" row, which
        -- sets moveDetail=true itself without going through the SELECT hook
        -- below. Hand off to the same manager instead of letting native's
        -- own reorder-only loop run underneath it.
        if GoldCompat.openMoveManager(self) then return end
      end

      if not self.moveDetail and input:wasPressed("select") then
        -- Native Gold only accepts SELECT on GREEN_PAGE. Temporarily expose
        -- that page to the original update for this frame so the engine
        -- itself sets up moveDetail/moveIndex the normal way, then take
        -- over with our own manager instead of leaving native's reorder
        -- loop running for any later input.
        local visiblePage=self.page
        self.page=SummaryMenu.GREEN_PAGE or 2
        SummaryMenu.__gen3uiOriginalUpdate(self,dt)
        self.page=visiblePage
        if self.moveDetail then GoldCompat.openMoveManager(self) end
        return
      end

      return SummaryMenu.__gen3uiOriginalUpdate(self,dt)
    end

    SummaryMenu.drawWidescreen=function(self,winW,winH)
      return GoldCompat.drawGoldSummary(self,winW,winH)
    end
  end

  local okDex,PokedexMenu=pcall(require,"src.ui.gen2.PokedexMenu")
  if okDex and type(PokedexMenu)=="table" and not PokedexMenu.__gen3uiVisualPatched then
    PokedexMenu.__gen3uiVisualPatched=true
    PokedexMenu.__gen3uiOriginalNew=PokedexMenu.new
    PokedexMenu.__gen3uiOriginalUpdate=PokedexMenu.update
    PokedexMenu.__gen3uiOriginalDrawPanel=PokedexMenu.drawPanel
    PokedexMenu.__gen3uiOriginalDrawWidescreen=PokedexMenu.drawWidescreen
    PokedexMenu.__gen3uiOriginalOpaque=PokedexMenu.isOpaque

    -- v2.1.33: native Gen 2 Pokédex is an opaque widescreen state.  Our
    -- reskin only paints hanging cards, so Game2 must explicitly draw the live
    -- world first.  Returning "world" is the engine's supported contract for
    -- that, while BG_WORLD_DIM=0 prevents paintBattleSurround from adding the
    -- same dark side bands that affected Party.  New-entry pages keep their
    -- native full-screen ownership because they can be invoked from battle/
    -- capture flow rather than the overworld START menu.
    PokedexMenu.BG_WORLD_DIM=0
    PokedexMenu.bgMode=function(self)
      return "world"
    end

    PokedexMenu.update=function(self,dt)
      if goldScreenEnabled("revampedPokedex") and not self.newEntry then
        local input=self.game and self.game.input

        if self.view=="entry" and input then
          if input:wasPressed("a") then
            self.view="locations"
            self.__gen3uiDexLocationScroll=0
            return
          elseif input:wasPressed("b") then
            self.view="list"
            return
          end
          -- PAGE/AREA/CRY/PRNT are replaced by the modern DATA -> LOCATIONS
          -- workflow, so no native action-bar input leaks through.
          return
        elseif self.view=="locations" and input then
          local rows=self.__gen3uiDexLocationRows
            or GoldCompat.dexCatchLocations(self,
              self:current() and self:current().species)
          local visible=8
          local maxScroll=math.max(0,#rows-visible)

          if input:wasPressed("up") then
            self.__gen3uiDexLocationScroll=math.max(0,
              (self.__gen3uiDexLocationScroll or 0)-1)
            return
          elseif input:wasPressed("down") then
            self.__gen3uiDexLocationScroll=math.min(maxScroll,
              (self.__gen3uiDexLocationScroll or 0)+1)
            return
          elseif input:wasPressed("a") or input:wasPressed("b") then
            self.view="list"
            self.__gen3uiDexLocationScroll=0
            return
          end
          return
        end
      end
      return PokedexMenu.__gen3uiOriginalUpdate(self,dt)
    end

    PokedexMenu.drawWidescreen=function(self,winW,winH)
      if goldScreenEnabled("revampedPokedex") then
        return GoldCompat.drawGoldPokedex(self,winW,winH)
      end
      return callOriginal(PokedexMenu.__gen3uiOriginalDrawWidescreen,
        self,winW,winH)
    end

    -- Belt-and-suspenders instance override: Screens may have resolved the
    -- Gen2PokedexMenu factory before this patch, but new instances still pass
    -- through this constructor and receive our widescreen renderer directly.
    PokedexMenu.new=function(...)
      local self=PokedexMenu.__gen3uiOriginalNew(...)
      local hanging=goldScreenEnabled("revampedPokedex") and not self.newEntry
      self.isOpaque=hanging and false or PokedexMenu.__gen3uiOriginalOpaque
      -- Game2's surround scan stops at the first state that exposes bgMode.
      -- Hide our injected method entirely for native/new-entry cases so the
      -- underlying battle/world state keeps the same surround behavior it had
      -- before this presentation patch.
      self.bgMode=hanging and PokedexMenu.bgMode or false
      self.drawWidescreen=function(inst,winW,winH)
        if goldScreenEnabled("revampedPokedex") then
          return GoldCompat.drawGoldPokedex(inst,winW,winH)
        end
        return callOriginal(PokedexMenu.__gen3uiOriginalDrawWidescreen,
          inst,winW,winH)
      end
      self.update=PokedexMenu.update
      self.drawsWidescreen=function() return true end
      self.wantsFillScale=function() return true end
      return self
    end
  end

  GoldCompat.coreMenusInstalled=true
end

function GoldCompat.installPokegearUI()
  if GoldCompat.generation~="gen2" or GoldCompat.pokegearInstalled then return end

  local ok,Pokegear=pcall(require,"src.ui.gen2.Pokegear")
  if not ok or type(Pokegear)~="table" then return end
  if Pokegear.__gen3uiPatched then
    GoldCompat.pokegearInstalled=true
    return
  end

  Pokegear.__gen3uiPatched=true
  Pokegear.__gen3uiOriginalDrawPanel=Pokegear.drawPanel
  Pokegear.__gen3uiOriginalDrawWidescreen=Pokegear.drawWidescreen

  Pokegear.drawWidescreen=function(self,winW,winH)
    if goldScreenEnabled("revampedPokegearUI") then
      return GoldCompat.drawPokegearWidescreen(self,winW,winH)
    end
    return callOriginal(
      Pokegear.__gen3uiOriginalDrawWidescreen,self,winW,winH)
  end

  GoldCompat.pokegearInstalled=true
end


function GoldCompat.buildLevelUpPopup(state,event)
  local battle=state and state.battle
  local mon=battle and battle.party and event and event.index
      and battle.party[event.index]
  if not mon then return nil end

  local Mon=GoldCompat.engineModule("src.battle.gen2.Mon")
  local def=state.pokemon and mon.species and state.pokemon[mon.species]
  local newStats=mon.stats or {}
  local oldStats={}
  if Mon and def and type(Mon.stats)=="function" then
    local ok,stats=pcall(Mon.stats,def.baseStats,mon.dvs,
      math.max(1,(event.level or mon.level or 1)-1),mon.statExp)
    if ok and type(stats)=="table" then oldStats=stats end
  end

  local function row(label,key)
    local now=tonumber(newStats[key]) or 0
    local old=tonumber(oldStats[key]) or now
    return {label=label,value=now,delta=now-old}
  end

  return {
    mon=mon,
    name=mon.nickname or mon.name or mon.species or "POKéMON",
    level=event.level or mon.level or 1,
    rows={
      row("HP","hp"),
      row("ATTACK","attack"),
      row("DEFENSE","defense"),
      row("SP. ATK","specialAttack"),
      row("SP. DEF","specialDefense"),
      row("SPEED","speed"),
    },
  }
end

function GoldCompat.drawGoldBattleLevelUp(state)
  if not (featureEnabled("revampedLevelUpUI")
      or featureEnabled("hideNativeBattleUI")) then
    if state then state.__gen3uiLevelPopup=nil end
    return false
  end
  local pop=state and state.__gen3uiLevelPopup
  if not pop then return false end
  local G=love.graphics
  local ox,oy,sc=finalCanvas()
  local x,y,w,h=49,18,62,96

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  G.setColor(0.02,0.03,0.03,0.52)
  roundedRect("fill",x+2,y+2,w,h,4)
  G.setColor(0.075,0.085,0.08,0.98)
  roundedRect("fill",x,y,w,h,4)
  G.setColor(0.32,0.35,0.32,1)
  roundedRect("line",x,y,w,h,4)
  G.setColor(0.79,0.64,0.20,1)
  G.rectangle("fill",x+5,y+5,w-10,1.2)
  G.setColor(0.14,0.15,0.14,1)
  roundedRect("fill",x+6,y+18,w-12,12,2)
  G.pop()

  finalText("LEVEL UP!",x+7,y+8,3.8,{0.97,0.97,0.93,1},ox,oy,sc)
  finalText("Lv. "..tostring(pop.level),x+w-22,y+8,2.9,
    {0.89,0.79,0.42,1},ox,oy,sc,"right",15)
  finalText(pop.name,x+10,y+21,2.9,{0.97,0.97,0.94,1},
    ox,oy,sc,"left",w-20)

  for i,row in ipairs(pop.rows or {}) do
    local yy=y+36+(i-1)*8
    finalText(row.label,x+9,yy,2.35,{0.70,0.72,0.68,1},ox,oy,sc)
    finalText(tostring(row.value),x+w-23,yy,2.8,
      {0.97,0.97,0.94,1},ox,oy,sc,"right",11)
    local d=tonumber(row.delta) or 0
    finalText((d>=0 and "+" or "")..tostring(d),x+w-13,yy,2.05,
      d>0 and {0.34,0.85,0.49,1} or {0.62,0.64,0.61,1},
      ox,oy,sc,"right",8)
  end

  finalText("A  CONTINUE",x+w-27,y+h-8,1.9,
    {0.70,0.72,0.68,1},ox,oy,sc,"right",23)
  return true
end

function GoldCompat.enemyBallsRemaining(state)
  local party=state and state.battle and state.battle.enemyParty or {}
  local n=0
  for _,mon in ipairs(party) do
    if mon and not mon.isEgg and (mon.hp or 0)>0 then n=n+1 end
  end
  return n,#party
end

function GoldCompat.drawGoldTrainerSwitchOverlay(state)
  local tr=state and state.__gen3uiTrainerSwitch
  if not (tr and state.enemyTrainerImage) then return false end

  -- FOUND (v2.1.31): user report ("still seeing the trainer icon popping up
  -- in between battles") + screenshot showing this flat pixel-art trainer
  -- sprite floating over a full 3D Colosseum Battle Environments arena.
  -- Investigated in v2.1.27 against real src/ui/gen2/BattleState.lua and
  -- confirmed this content is genuine, correct vanilla presentation
  -- (offerShiftSwitch's own real "TRAINER is about to send out MON" cue,
  -- reusing the same cached enemyTrainerImage the real battle intro uses) --
  -- that conclusion stands; this isn't a rendering defect. But it was never
  -- checked against an active full-frame 3D battle renderer specifically,
  -- and a flat 2D sprite pasted over CBE's own 3D showroom scene is exactly
  -- the kind of native-presentation clash this mod already steps aside for
  -- everywhere else (GoldCompat.ownsNativeBattleLayer/hidesAllNativeBattle
  -- Presentation) -- CBE's own 3D trainer actor is presumably what should
  -- represent this same moment when it owns the battle, not this 2D pic.
  -- Skip drawing it entirely in that case; unchanged otherwise.
  -- (shouldDeferNativeSuppression is the "does a compliant full-frame
  -- renderer already own this battle's world" check itself -- the same
  -- predicate GoldCompat.ownsNativeBattleLayer's own gate is built from --
  -- not hidesAllNativeBattlePresentation, which only tracks the player's own
  -- HIDE NATIVE BATTLE UI toggle and says nothing about CBE.)
  if GoldCompat.shouldDeferNativeSuppression(state) then return false end

  local G=love.graphics
  local ox,oy,sc=finalCanvas()
  local frames=12
  local phase=math.min(1,(tr.frame or 0)/frames)
  local t=(tr.mode=="out") and (1-phase) or phase
  t=math.max(0,math.min(1,t))

  local img=state.enemyTrainerImage
  local iw,ih=img:getDimensions()

  -- Exact Gen 2 enemy pic box used by the intro: tile (12,0), 7x7.
  local boxX,boxY,boxSize=96,0,56
  local scale=1
  if type(state.picScale)=="function" then
    local ok,value=pcall(state.picScale,state,state.enemyTrainerPath,nil,false)
    if ok and tonumber(value) then scale=tonumber(value) end
  end

  local px=boxX+(boxSize-iw*scale)/2
  local py=boxY+(boxSize-ih*scale)
  -- Slide from the right into the normal battle-intro position.
  px=px+(1-t)*boxSize

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  G.setColor(1,1,1,1)

  local drew=false
  local Palettes=GoldCompat.engineModule("src.world.gen2.Palettes")
  local GbcPalette=GoldCompat.engineModule("src.render.GbcPalette")
  local colors=Palettes and state.palettes and type(Palettes.trainerColors)=="function" and
    Palettes.trainerColors(state.palettes,state.enemyTrainerClass) or nil

  local function body()
    G.draw(img,px,py,0,scale,scale)
  end
  if colors and GbcPalette and GbcPalette.available
      and GbcPalette.available() then
    local ok=pcall(GbcPalette.with,colors,body)
    drew=ok
  end
  if not drew then body() end

  -- Switch-only party indicator using a proper Poké Ball glyph.
  local remaining,total=GoldCompat.enemyBallsRemaining(state)
  local count=math.max(total,remaining)
  local ballY=12
  local ballX=10
  for i=1,count do
    local alive=i<=remaining
    local cx=ballX+(i-1)*7
    local r=2.35
    if alive then
      G.setColor(0.90,0.18,0.14,1)
      G.arc("fill","pie",cx,ballY,r,math.pi,math.pi*2)
      G.setColor(0.98,0.98,0.94,1)
      G.arc("fill","pie",cx,ballY,r,0,math.pi)
      G.setColor(0.08,0.08,0.07,1)
      G.setLineWidth(0.7)
      G.circle("line",cx,ballY,r)
      G.line(cx-r,ballY,cx+r,ballY)
      G.setColor(0.98,0.98,0.94,1)
      G.circle("fill",cx,ballY,r*0.28)
    else
      G.setColor(0.38,0.39,0.37,0.52)
      G.setLineWidth(0.7)
      G.circle("line",cx,ballY,r)
      G.line(cx-r,ballY,cx+r,ballY)
    end
  end
  G.pop()
  return true
end

function GoldCompat.drawEnemyTrainerPartyIndicator(state)
  -- Intro only.  During replacement switches the already-working
  -- drawGoldTrainerSwitchOverlay owns this indicator instead.
  if not (state and state.enemyTrainerImage and state.showEnemyTrainer
      and state.phase=="intro" and not state.__gen3uiTrainerSwitch) then
    return false
  end

  local remaining,total=GoldCompat.enemyBallsRemaining(state)
  if total<=0 then return false end

  local G=love.graphics
  local ox,oy,sc=finalCanvas()
  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)

  local ballY=12
  local ballX=10
  for i=1,total do
    local alive=i<=remaining
    local cx=ballX+(i-1)*7
    local r=2.35

    if alive then
      G.setColor(0.90,0.18,0.14,1)
      G.arc("fill","pie",cx,ballY,r,math.pi,math.pi*2)
      G.setColor(0.98,0.98,0.94,1)
      G.arc("fill","pie",cx,ballY,r,0,math.pi)
      G.setColor(0.08,0.08,0.07,1)
      G.setLineWidth(0.7)
      G.circle("line",cx,ballY,r)
      G.line(cx-r,ballY,cx+r,ballY)
      G.setColor(0.98,0.98,0.94,1)
      G.circle("fill",cx,ballY,r*0.28)
    else
      G.setColor(0.38,0.39,0.37,0.52)
      G.setLineWidth(0.7)
      G.circle("line",cx,ballY,r)
      G.line(cx-r,ballY,cx+r,ballY)
    end
  end

  G.pop()
  return true
end

function GoldCompat.drawGoldBattleChoice(state)
  if not state then return false end
  local asking=state.phase=="ask-shift"
      or state.phase=="ask-nickname"
      or state.phase=="ask-forget"
      or state.phase=="stop-learning"
  if not asking or (state.messageTimer or 0)>0 then return false end

  local index=state.phase=="ask-shift" and (state.shiftIndex or 1)
      or state.phase=="ask-nickname" and (state.nicknameIndex or 1)
      or (state.forgetChoice or 1)

  local G=love.graphics
  local ox,oy,sc=finalCanvas()
  local x,y,w,h=119,58,34,28

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)
  G.setColor(0.03,0.04,0.04,0.42)
  roundedRect("fill",x+2,y+2,w,h,3)
  G.setColor(0.08,0.09,0.08,0.98)
  roundedRect("fill",x,y,w,h,3)
  G.setColor(0.98,0.975,0.93,1)
  roundedRect("fill",x+2,y+2,w-4,h-4,2)

  for i=1,2 do
    local yy=y+5+(i-1)*10
    if index==i then
      G.setColor(0.11,0.28,0.38,1)
      roundedRect("fill",x+5,yy-1,w-10,8,1.2)
      G.setColor(1.0,0.36,0.16,1)
      G.rectangle("fill",x+5,yy-1,1.2,8)
    end
  end
  G.pop()

  finalText("YES",x+10,y+5,2.7,
    index==1 and {1,1,1,1} or {0.07,0.07,0.07,1},ox,oy,sc)
  finalText("NO",x+10,y+15,2.7,
    index==2 and {1,1,1,1} or {0.07,0.07,0.07,1},ox,oy,sc)
  return true
end

function GoldCompat.installGoldBattlePresentation()
  if GoldCompat.generation~="gen2" or goldBattleScrubInstalled then return end
  goldBattleScrubInstalled=true

  local ok,GoldBattleState=pcall(require,"src.ui.gen2.BattleState")
  if not (ok and GoldBattleState and type(GoldBattleState.drawPanel)=="function")
      then return end
  if GoldBattleState.__gen3uiPanelScrubbed then return end
  GoldBattleState.__gen3uiPanelScrubbed=true

  local original=GoldBattleState.drawPanel
  GoldBattleState.__gen3uiOriginalAdvanceQueue=GoldBattleState.advanceQueue
  GoldBattleState.__gen3uiOriginalOfferShiftSwitch=GoldBattleState.offerShiftSwitch
  GoldBattleState.__gen3uiOriginalUpdate=GoldBattleState.update

  -- Gold's native level/stat card is outside drawPanel's three tile regions.
  -- Preserve its callback while making every pixel inert under UI ownership.
  if type(GoldBattleState.drawStatsBox)=="function"
      and not GoldBattleState.__gen3uiStatsScrubbed then
    GoldBattleState.__gen3uiStatsScrubbed=true
    local originalStatsBox=GoldBattleState.drawStatsBox
    GoldBattleState.drawStatsBox=function(self,...)
      -- Use runDrawInvisible (scissor-clipped, paints nothing) rather than
      -- gating on ownsNativeBattleLayer()/shouldDeferNativeSuppression()
      -- directly: those correctly return false while a 3D renderer owns the
      -- battle (so the white-rectangle erase technique in drawPanel doesn't
      -- paint over that renderer's own scene), but runDrawInvisible never
      -- paints anything in the first place, so it carries none of that risk
      -- and should still suppress the native stat card even during a CBE
      -- battle -- CBE has no reason to know about Gold's own drawStatsBox,
      -- so leaving it unsuppressed there would show native UI unexpectedly
      -- (the same class of bug drawPanel had before this same v2.1.10 pass).
      if battleUiPresentationEnabled() then
        return runDrawInvisible(originalStatsBox,self,...)
      end
      return originalStatsBox(self,...)
    end
  end

  GoldBattleState.advanceQueue=function(self,...)
    -- The next native queue item is still visible here, before the engine
    -- removes it. Capture LEVEL at the same moment the "grew to level" line
    -- becomes current.
    local event=self.queue and self.queue[1]
    if self.__gen3uiLevelPopup and (not event or event.kind~="level") then
      self.__gen3uiLevelPopup=nil
    end
    if event and event.kind=="level"
        and (featureEnabled("revampedLevelUpUI")
          or featureEnabled("hideNativeBattleUI")) then
      self.__gen3uiLevelPopup=GoldCompat.buildLevelUpPopup(self,event)
    elseif event and event.kind=="level" then
      self.__gen3uiLevelPopup=nil
    end
    return GoldBattleState.__gen3uiOriginalAdvanceQueue(self,...)
  end

  GoldBattleState.offerShiftSwitch=function(self,mon,...)
    self.__gen3uiTrainerSwitch={mode="in",frame=0}
    return GoldBattleState.__gen3uiOriginalOfferShiftSwitch(self,mon,...)
  end

  GoldBattleState.update=function(self,...)
    -- The level-up stat card is a real acknowledgement screen, not a timed
    -- animation.  Hold the underlying Gold battle state here so emulator/game
    -- speed cannot race past it. A (or B) dismisses and then native queue
    -- processing resumes on the following frame.
    if self.__gen3uiLevelPopup then
      local input=self.game and self.game.input
      if input and (input:wasPressed("a") or input:wasPressed("b")) then
        self.__gen3uiLevelPopup=nil
        self.messageTimer=0
      end
      return
    end

    local before=self.phase
    local result=GoldBattleState.__gen3uiOriginalUpdate(self,...)
    -- replacement prompt. Repair that state without touching native hide/show
    -- behavior for faint/send-out animation phases.
    if self.__gen3uiShiftPicHidden~=nil then
      if self.picHidden and self.enemy and self.enemy.mon
          and self.phase~="enemy-faint" and self.phase~="enemy-sendout" then
        self.picHidden.enemy=false
      end
      self.__gen3uiShiftPicHidden=nil
    end
    local tr=self.__gen3uiTrainerSwitch
    if tr then
      if before=="ask-shift" and self.phase~="ask-shift" and tr.mode=="in" then
        tr.mode="out"
        tr.frame=0
      else
        tr.frame=(tr.frame or 0)+1
      end
      if tr.mode=="out" and tr.frame>=12 then
        self.__gen3uiTrainerSwitch=nil
      end
    end
    return result
  end

  GoldBattleState.drawPanel=function(self,...)
    -- Gold draws its own YES/NO box inside drawPanel. While our battle UI is
    -- active, temporarily keep its message timer positive for this draw only,
    -- which suppresses that native box without touching input or battle flow.
    local suppressChoice=battleUiPresentationEnabled()
      and (self.phase=="ask-shift" or self.phase=="ask-nickname"
        or self.phase=="ask-forget" or self.phase=="stop-learning")
      and (self.messageTimer or 0)<=0
    local timer=self.messageTimer
    if suppressChoice then self.messageTimer=1 end

    -- v2.1.9 fixed the CBE/3D-renderer white box here (this call site never
    -- consulted GoldCompat.ownsNativeBattleLayer at all -- see the history
    -- below), but naively gated only the ERASE step while `original(self,...)`
    -- below still always ran unconditionally. When a compliant 3D renderer
    -- owns the battle, ownsNativeBattleLayer() correctly returns false, so
    -- the erase got skipped -- but original() had already painted Gold's
    -- real native HUD/text/menu pixels moments earlier with nothing left to
    -- cover them, so native UI showed through in full underneath our own
    -- styled cards instead of being hidden by either the white erase or a 3D
    -- scene. v2.1.10 fixes this properly: when deferring to a 3D renderer,
    -- suppress ALL of drawPanel's pixel output via runDrawInvisible (same
    -- scissor-based technique drawStatsBox already uses successfully) so
    -- nothing native ever reaches the frame and the renderer's own scene is
    -- never painted over either. The plain case (no 3D renderer) keeps the
    -- original draw-then-erase behavior unchanged -- it was never broken.
    if GoldCompat.shouldDeferNativeSuppression(self) then
      local result=runDrawInvisible(original,self,...)
      if suppressChoice then self.messageTimer=timer end
      return result
    end

    local result=original(self,...)
    if suppressChoice then self.messageTimer=timer end
    -- FOUND (v2.1.9): this was the actual source of the white box reported
    -- with CBE (or any other full-frame 3D battle renderer) on Gen II saves.
    -- v2.1.5 fixed the equivalent Gen I race in patchVanillaTextDrawing's
    -- BattleState.drawTextArea/drawHUDs wrappers, but Gold's presentation
    -- goes through this completely separate GoldBattleState.drawPanel path
    -- (see the comment on patchVanillaTextDrawing's early Gen II return) --
    -- that fix never reached here. drawStatsBox right above already correctly
    -- gates its own suppression on GoldCompat.ownsNativeBattleLayer(self);
    -- this erase block used a plain featureEnabled() check instead and
    -- unconditionally painted three solid white rectangles over Gold's
    -- native HUD/text/command tile regions on every revamped-battle-UI draw.
    if GoldCompat.ownsNativeBattleLayer(self) then
      -- Erase only Gold's native HUD/text/menu tile regions after it has drawn.
      -- Pokémon/trainer pictures occupy the complementary parts of the 160x144
      -- battle canvas and remain fully engine-owned. Reached only when NOT
      -- deferring to a 3D renderer (handled above), so painting solid white
      -- here is safe -- there is no 3D backdrop underneath to overwrite.
      local g=love.graphics
      g.push("all")
      g.setColor(1,1,1,1)
      g.rectangle("fill",0,0,88,34)       -- enemy HUD
      g.rectangle("fill",70,54,90,43)     -- player HUD
      g.rectangle("fill",0,96,160,48)     -- text / command / move area
      g.pop()
    end
    return result
  end
end

local function battleOverlayHook(next,battle)
  -- Never paint over the completed battlefield. Wide/native HUD suppression is
  -- handled before those UI primitives draw; this hook only preserves overlay
  -- chaining and active battle ownership.
  next(battle)
  State.activeBattle=battle
end

local function clearStaleOverworldOwnership(game)
  local topNow=topState(game)
  if topNow and not GoldCompat.supportedOverworldMenuState(topNow)
      and not topNow.__gen3uiStart
      and getmetatable(topNow)~=TextBox
      and getmetatable(topNow)~=ChoiceBox
      and getmetatable(topNow)~=NamingScreen
      and topNow~=State.activeBattle then
    State.activeStartMenu=nil
    State.activeBagMenu=nil
    State.activeBagActionMenu=nil
  end
end


function GoldCompat.renderMartForeground(mod,game)
  if not featureEnabled("revampedPokeMartUI") then return false end

  local shopTop=topState(game)
  if not shopTop then return false end

  if shopTop.__gen3uiMartRenderFailed then return false end

  if shopTop.__gen3uiShopMain then
    State.activeShopMenu=shopTop
    State.activeShopList=nil
    State.activeShopQuantity=nil
    local ok,err=pcall(drawShopMainFinal,game,shopTop)
    if not ok then
      shopTop.__gen3uiMartRenderFailed=true
      State.activeShopMenu=nil
      if mod.log then
        mod.log:error("Gen 3 UI Mart main failed; falling back native: "..tostring(err))
      end
      return false
    end
    return true
  end

  if shopTop.__gen3uiShopList then
    State.activeShopList=shopTop
    State.activeShopMenu=nil
    State.activeShopQuantity=nil

    local ok,err=pcall(drawShopListFinal,game,shopTop)
    if not ok then
      shopTop.__gen3uiMartRenderFailed=true
      if mod.log then
        mod.log:error("Gen 3 UI Mart list failed; falling back native: "
          ..tostring(err))
      end
      return false
    end
    return true
  end

  if shopTop.__gen3uiShopQuantity then
    local under=shopStateInStack(game)
    if under and under.__gen3uiShopList then
      State.activeShopQuantity=shopTop
      local ok,err=pcall(GoldCompat.drawShopQuantityFinal,game,under,shopTop)
      if (not ok) and mod.log then
        mod.log:error("Gen 3 UI Mart quantity failed: "..tostring(err))
      end
      return true
    end
  end

  return false
end

function GoldCompat.renderMartUnderlay(game)
  if not featureEnabled("revampedPokeMartUI") then return end
  if not (State.activeDialogueBox or State.activeChoiceBox) then return end

  local shopUnder=shopStateInStack(game)
  if not shopUnder then return end

  if shopUnder.__gen3uiShopList then
    pcall(drawShopListFinal,game,shopUnder)
  elseif shopUnder.__gen3uiShopMain then
    pcall(drawShopMainFinal,game,shopUnder)
  end
end

-- The floor list is always the topmost stack state while it's up (native
-- pushes the "Which floor..." TextBox first, then the ListMenu on top of
-- it once shown -- see data/scripts/story3.lua's `elevator()`), so this
-- mirrors GoldCompat.renderMartForeground's "topmost state IS this exact
-- screen" dispatch rather than the underlay pattern used when a dialogue
-- box sits on top of an already-drawn menu underneath it.
function GoldCompat.renderElevatorForeground(mod,game)
  if not featureEnabled("revampedOverworldMenus") then return false end
  local top=topState(game)
  if not (top and top.__gen3uiElevator) then return false end
  if top.__gen3uiElevatorRenderFailed then return false end

  local ok,err=pcall(drawElevatorFloorsFinal,game,top)
  if not ok then
    top.__gen3uiElevatorRenderFailed=true
    if mod.log then
      mod.log:error("Gen 3 UI elevator floor list failed; falling back native: "
        ..tostring(err))
    end
    return false
  end
  return true
end


function GoldCompat.renderHudUnderlays(mod,game)
  clearStaleOverworldOwnership(game)

  -- NamingScreen is a complete opaque native UI with its own letter grid.
  -- Never composite our menus/dialogue/battle HUD over it. This also makes
  -- mod-provided naming screens using the standard screenId contract fail-soft.
  if GoldCompat.namingScreenOwnsForeground(game) then
    State.activeDialogueBox=nil
    State.activeChoiceBox=nil
    clearOverworldMenuState()
    clearPokemonUIState()
    State.activeBattleMoveLearn=nil
    State.activeBattleMoveParty=nil
    clearShopUIState()
    clearPCUIState()
    return true
  end


  -- Gold compatibility mode deliberately leaves every non-battle Gen 2
  -- screen native. This prevents the 1.3.2 Gen 1 ListMenu/BagMenu/Summary/PC
  -- renderers from assuming structures Gold does not have.
  if GoldCompat.isGen2Game(game) then
    State.activeParty=nil
    State.activeTMParty=nil
    State.activeItemTargetParty=nil
    State.activeMoveLearn=nil
    State.activeTMPromptFlow=nil
    State.activeBagMenu=nil
    State.activeBagActionMenu=nil
    State.activePCMenu=nil
    State.activePCList=nil
    State.activePCActionMenu=nil
    State.activePCAccessMenu=nil
    State.activeShopMenu=nil
    State.activeShopList=nil
    State.activeShopQuantity=nil

    -- Gen 2's TM/HM forget-move flow pops its own PartyMenu before pushing
    -- the TextBox/MoveDeleter chain that finishes the flow (see the
    -- PartyMenu.new/Game2Module.learnMoveOn/MoveDeleter2 wraps in
    -- installCoreMenuUI) -- so the popped card has to be redrawn by hand as
    -- a background here, mirroring the Gen 1 "TM Party is a persistent
    -- background layer" block further down in this same function (Gen 1
    -- needs that block for a different reason: its BagMenu keeps the real
    -- PartyMenu ON the stack throughout, so it only has to re-render
    -- something the engine would otherwise already be drawing). Placed
    -- before every early-return below so it still paints regardless of
    -- which one of them ends up firing this frame (dialogue box, start
    -- menu, battle, ...).
    if State.activeGen2MoveLearn
        and (featureEnabled("revampedPokemonMenu")
          or GoldCompat.strictBattleUiForGame(game)) then
      local flow=State.activeGen2MoveLearn
      local okFlow,errFlow=pcall(GoldCompat.drawGoldPartyMenu,flow.party,0,0)
      if (not okFlow) and mod.log then
        mod.log:error(
          "Gen 3 UI Gen2 move-learn party background failed: "..tostring(errFlow))
      end
    end

    -- MoveDeleter.draw marks the live selection screen, but once native pops
    -- that state there is no later draw call on the same object to clear the
    -- marker.  Clear it structurally here so the post-selection "Poof / forgot
    -- / learned" TextBoxes immediately return to the normal full dialogue
    -- layout instead of being mistaken for the still-active picker.
    if State.activeGen2MoveDeleter
        and not stateExistsInStack(game,State.activeGen2MoveDeleter) then
      State.activeGen2MoveDeleter=nil
    end

    -- activeGen2TMParty has no natural single native "this flow is over"
    -- callback to hook (onCancel, onChoose-invalid, and learnMoveOn's onDone
    -- are all separate paths), so clean it up structurally instead: once the
    -- picker is no longer in the real stack AND we are not mid-move-learn for
    -- it (that flow deliberately keeps it alive past the pop), it has served
    -- its purpose.
    if State.activeGen2TMParty
        and not partyInStack(game,State.activeGen2TMParty)
        and not (State.activeGen2MoveLearn
          and State.activeGen2MoveLearn.party==State.activeGen2TMParty) then
      State.activeGen2TMParty=nil
    end

    -- Gold START and our Pack/Mart/Center-PC service overlays are
    -- presentation-suppressed and rendered later in render.hud over the live
    -- overworld. Do not consume those screens in the native Gold guard.
    local goldTop=topState(game)
    -- Safety net for ItemPcMenu instances created before/around a hot-reload:
    -- identify the real class directly before this Gen 2 guard can consume it
    -- as an unsupported opaque screen.
    if goldTop and GoldCompat.itemPcClass
        and getmetatable(goldTop)==GoldCompat.itemPcClass
        and featureEnabled("revampedItemPCUI") then
      goldTop.isOpaque=false
      goldTop.__gen3uiGoldOverlayKind="itempc"
    end
    if goldTop and goldTop.__gen3uiGoldOverlayKind then
      return false
    end
    if State.activeStartMenu and uiTopState(game,State.activeStartMenu) then
      return false
    end

    -- Shared Gold TextBox/ChoiceBox owns the foreground. Its native draw is
    -- suppressed by installDialogueThemeDirect(), so allow the next HUD stage
    -- to render the existing Gen 3 dialogue/choice presentation.
    if State.activeDialogueBox or State.activeChoiceBox then
      return false
    end

    local battle=State.activeBattle
    if not battleUiPresentationEnabled() then
      State.activeBattle=nil
      return true
    end
    if not battleInStack(game,battle) or not battleOwnsForeground(game,battle) then
      return true
    end

    local visualBattle=GoldCompat.presentBattleState(battle)
    local cmd=commandGeometry()
    local s=hudScale()

    love.graphics.push("all")
    local okStatus,errStatus=pcall(function()
      if shouldDrawStatusHUD(game,visualBattle) then
        drawEnemyHUD(visualBattle,s)
        drawPlayerHUD(visualBattle,s,cmd)
      end
    end)

    love.graphics.pop()

    love.graphics.push("all")
    local okUI,errUI=pcall(function()
      drawDialogue(visualBattle)
      drawCommandMenu(visualBattle)
      drawMoveSelect(visualBattle)
      GoldCompat.drawEnemyTrainerPartyIndicator(battle)
      GoldCompat.drawGoldTrainerSwitchOverlay(battle)
      GoldCompat.drawGoldBattleChoice(battle)
      GoldCompat.drawGoldBattleLevelUp(battle)
    end)
    love.graphics.pop()

    if mod.log then
      if not okStatus then
        mod.log:error("Gen 3 UI Gold battle HUD failed: "..tostring(errStatus))
      end
      if not okUI then
        mod.log:error("Gen 3 UI Gold battle panels failed: "..tostring(errUI))
      end
    end
    return true
  end

  if GoldCompat.renderMartForeground(mod,game) then return true end
  if GoldCompat.renderElevatorForeground(mod,game) then return true end

  local pushedBattle=battleStateInStack(game)
  local topForBattle=topState(game)

  if State.activeBattleMoveLearn
      and topForBattle==State.activeBattleMoveLearn
      and pushedBattle
      and battleUiPresentationEnabled()
      and (featureEnabled("revampedPokemonMenu")
        or GoldCompat.strictBattleUiForGame(game)) then
    State.activeBattle=pushedBattle

    if not State.activeBattleMoveParty then
      State.activeBattleMoveParty=makeBattleMovePartyState(game,State.activeBattleMoveLearn)
    end

    if State.activeBattleMoveParty then
      local okParty,errParty=pcall(drawPartyFinal,game,State.activeBattleMoveParty)
      if not okParty then
        State.activeBattleMoveParty=nil
        if mod.log then
          mod.log:error("Gen 3 UI battle MoveLearn Party failed; native fallback: "
            ..tostring(errParty))
        end
        -- Do not terminate the HUD pass on a presentation failure.
      else
        return true
      end
    end
  elseif State.activeBattleMoveLearn
      and not stateExistsInStack(game,State.activeBattleMoveLearn) then
    State.activeBattleMoveLearn=nil
    State.activeBattleMoveParty=nil
  end


  -- Bill's PC / storage screens use the same full-resolution visual
  -- language as Party. Only explicitly marked PC states are intercepted.
  local pcTop=topState(game)
  if pcTop and isPCOwnedState(pcTop) and featureEnabled("revampedPokemonPC") then
    if pcTop.__gen3uiPCAccess then
      State.activePCAccessMenu=pcTop
      State.activePCMenu=nil
      State.activePCList=nil
      State.activePCActionMenu=nil
      local ok,err=pcall(drawPCAccessFinal,game,pcTop)
      if (not ok) and mod.log then
        mod.log:error("Gen 3 UI PC access renderer failed: "..tostring(err))
      end
      return true
    elseif pcTop.__gen3uiPCMain then
      State.activePCMenu=pcTop
      State.activePCAccessMenu=nil
      State.activePCList=nil
      State.activePCActionMenu=nil
      local ok,err=pcall(drawPCMainFinal,game,pcTop)
      if (not ok) and mod.log then
        mod.log:error("Gen 3 UI PC main renderer failed: "..tostring(err))
      end
      return true
    elseif pcTop.__gen3uiPCList then
      State.activePCList=pcTop
      State.activePCAccessMenu=nil
      State.activePCMenu=nil
      State.activePCActionMenu=nil
      local ok,err=pcall(drawPCListFinal,game,pcTop)
      if (not ok) and mod.log then
        mod.log:error("Gen 3 UI PC list renderer failed: "..tostring(err))
      end
      return true
    elseif pcTop.__gen3uiPCAction then
      State.activePCActionMenu=pcTop
      local ok,err=pcall(drawPCActionFinal,game,pcTop)
      if (not ok) and mod.log then
        mod.log:error("Gen 3 UI PC action renderer failed: "..tostring(err))
      end
      return true
    end
  end

  if State.activeMoveLearn and not stateExistsInStack(game, State.activeMoveLearn) then
    State.activeMoveLearn = nil
  end
  if State.activeTMPromptFlow and not stateExistsInStack(game, State.activeTMPromptFlow) then
    State.activeTMPromptFlow = nil
  end

  -- Generic Bag item target picker: stones, medicine, PP items, etc.
  local itemPartyTop=topState(game)
  if itemPartyTop
      and (itemPartyTop.__gen3uiItemTarget
        or itemPartyTop.__gen3uiKeepTMBackground)
      and (featureEnabled("revampedPokemonMenu")
        or GoldCompat.strictBattleUiForGame(game)) then
    State.activeItemTargetParty=itemPartyTop
    State.activeParty=itemPartyTop
    State.activeBagActionMenu=nil
    State.activeBagMenu=nil

    local okItemParty,errItemParty=pcall(drawPartyFinal,game,itemPartyTop)
    if not okItemParty then
      if mod.log then
        mod.log:error("Gen 3 UI item-target Party renderer failed: "
          ..tostring(errItemParty))
      end
    else
      return true
    end
  elseif State.activeItemTargetParty
      and not stateExistsInStack(game,State.activeItemTargetParty) then
    State.activeItemTargetParty=nil
  end

  -- Bag-owned USE/TOSS menu. Detect the actual top state directly so the
  -- themed Bag+action overlay exists on the very first frame, before Menu.draw
  -- has had any chance to set ownership.
  local bagActionTop=topState(game)
  if bagActionTop
      and bagActionTop.__gen3uiBagAction
      and (featureEnabled("revampedOverworldMenus")
        or GoldCompat.strictBattleUiForGame(game)) then
    State.activeBagActionMenu=bagActionTop
    local bag=bagStateForMenu(game)

    if bag then
      local okBagBg,errBagBg=pcall(drawBagFinal,game,bag)
      if (not okBagBg) and mod.log then
        mod.log:error("Gen 3 UI Bag action background failed: "..tostring(errBagBg))
      end

      local okAction,errAction=pcall(GoldCompat.drawBagActionFinal,game,bagActionTop)
      if (not okAction) and mod.log then
        mod.log:error("Gen 3 UI Bag action overlay failed: "..tostring(errAction))
      end
      return true
    end
  elseif State.activeBagActionMenu
      and not stateExistsInStack(game,State.activeBagActionMenu) then
    State.activeBagActionMenu=nil
  end

  -- During TM/HM boot-up dialogue the actual Bag ListMenu is still in
  -- game.stack underneath the TextBox. Draw THAT live state directly.
  -- This is intentionally independent of whether ListMenu.draw ran this frame.
  if State.activeDialogueBox
      and (featureEnabled("revampedOverworldMenus")
        or GoldCompat.strictBattleUiForGame(game))
      and not (State.activeParty and partyTopState(game,State.activeParty)) then
    local bagUnderDialogue = bagStateForMenu(game)
    if bagUnderDialogue then
      local okBagBg, errBagBg = pcall(drawBagFinal, game, bagUnderDialogue)
      if (not okBagBg) and mod.log then
        mod.log:error("Gen 3 UI live Bag underlay failed: "..tostring(errBagBg))
      end
    end
  end

  -- TM/HM Party is a persistent BACKGROUND layer. It must render before
  -- dialogue/teach overlays, because those overlays may return from this HUD pass.
  if State.activeTMParty then
    local tmBackgroundWanted =
      partyShouldRenderBehindTM(game, State.activeTMParty)
      or (State.activeTMPromptFlow and stateExistsInStack(game, State.activeTMParty))

    if (featureEnabled("revampedPokemonMenu")
        or GoldCompat.strictBattleUiForGame(game)) and tmBackgroundWanted then
      local okTMParty, errTMParty = pcall(drawPartyFinal, game, State.activeTMParty)
      if (not okTMParty) and mod.log then
        mod.log:error("Gen 3 Inspired UI Overhaul TM Party background failed: "..tostring(errTMParty))
      end
    elseif not partyInStack(game, State.activeTMParty) then
      State.activeTMParty = nil
    end
  end

  -- PC-owned TextBox/ChoiceBox prompts sit above BoxMenu/ListMenu on the
  -- native stack. Re-render the nearest marked PC state here so confirmation
  -- and transfer messages retain our custom PC background, never native chrome.
  if (State.activeDialogueBox or State.activeChoiceBox)
      and featureEnabled("revampedPokemonPC") then
    local pcUnder=pcStateInStack(game)
    if pcUnder then
      if pcUnder.__gen3uiPCAccess then
        pcall(drawPCAccessFinal,game,pcUnder)
      elseif pcUnder.__gen3uiPCMain then
        pcall(drawPCMainFinal,game,pcUnder)
      elseif pcUnder.__gen3uiPCList then
        pcall(drawPCListFinal,game,pcUnder)
      elseif pcUnder.__gen3uiPCAction then
        pcall(drawPCActionFinal,game,pcUnder)
      end
    end
  end


  GoldCompat.renderMartUnderlay(game)

  -- The SAVE info panel (PLAYER/BADGES/POKéDEX/TIME) is tagged by
  -- installGen1SaveScreen the instant StateStack:push sees it, and it sits
  -- on the stack alone for ~30 native frames before the "Would you like to
  -- SAVE the game?" TextBox/ChoiceBox ever appears above it -- so this check
  -- deliberately does not gate on activeDialogueBox/activeChoiceBox the way
  -- the Mart/PC underlays above do; it must draw every frame the panel is
  -- present, confirm box or not. On a render failure, flag the panel so the
  -- push-time wrapper's native fallback takes over instead of erroring again.
  if featureEnabled("revampedSaveUI") then
    local saveUnder=savePanelInStack(game)
    if saveUnder then
      local okSave=pcall(GoldCompat.drawGen1SavePanelFinal,game,saveUnder)
      if not okSave then
        saveUnder.__gen3uiSaveRenderFailed=true
      end
    end
  end


  return false
end

function GoldCompat.renderHudDialogueLayer(mod,game)
  -- Dialogue/choices were marked by their native draw calls earlier this frame.
  -- Render ONLY the themed version now, outside the palette compositor.
  local drewDialogue = false

  if State.activeDialogueBox
      and (featureEnabled("revampedDialogueBoxes")
        or GoldCompat.strictBattleUiForGame(game)) then
    local box = State.activeDialogueBox
    State.activeDialogueBox = nil

    local okDialogue, errDialogue = pcall(GoldCompat.drawDialogueThemeFinal, box)
    if not okDialogue then
      if mod.log then
        mod.log:error("Gen 3 UI final dialogue overlay failed: "..tostring(errDialogue))
      end
    end
    drewDialogue=okDialogue
  else
    State.activeDialogueBox = nil
  end

  if State.activeChoiceBox
      and (featureEnabled("revampedDialogueBoxes")
        or GoldCompat.strictBattleUiForGame(game)) then
    local choice = State.activeChoiceBox
    State.activeChoiceBox = nil

    -- The starter confirmation owns one complete full-screen flow. Its exact
    -- ChoiceBox is claimed by the parity layer before this hook runs, so do not
    -- also paint the generic YES/NO card at the edge of the screen.
    if choice.__gen3uiStarterSpecies then return true end

    -- Battle sayChoice pushes ChoiceBox ABOVE BattleState while keeping the
    -- completed prompt in battle.current. Draw that prompt explicitly before
    -- the choice; otherwise our normal battle renderer yields to the pushed
    -- state and the user sees the previous "about to use" page freeze.
    local battleUnderChoice=State.activeBattle
    if battleInStack(game,battleUnderChoice)
        and battleUnderChoice.phase=="messages"
        and battleUnderChoice.current then
      local okPrompt,errPrompt=pcall(drawDialogue,battleUnderChoice)
      if (not okPrompt) and mod.log then
        mod.log:error("Gen 3 UI battle choice prompt failed: "..tostring(errPrompt))
      end
    end

    local okChoice, errChoice = pcall(GoldCompat.drawChoiceThemeFinal, choice)
    if (not okChoice) and mod.log then
      mod.log:error("Gen 3 UI final choice overlay failed: "..tostring(errChoice))
    end
    return true
  else
    State.activeChoiceBox = nil
  end

  if drewDialogue then
    return true
  end


  return false
end

function GoldCompat.renderGoldServiceOverlay(mod,game)
  if GoldCompat.generation~="gen2" then return false end
  local top=topState(game)
  if not top or not top.__gen3uiGoldOverlayKind then return false end

  local kind=top.__gen3uiGoldOverlayKind
  local ok,err
  if kind=="pack" then
    ok,err=pcall(GoldCompat.drawGoldPack,top,
      love.graphics.getWidth(),love.graphics.getHeight(),false)
  elseif kind=="mart" then
    ok,err=pcall(GoldCompat.drawGoldMart,top,
      love.graphics.getWidth(),love.graphics.getHeight())
  elseif kind=="centerpc" then
    ok,err=pcall(GoldCompat.drawGoldCenterPc,top,
      love.graphics.getWidth(),love.graphics.getHeight())
  elseif kind=="itempc" then
    if not featureEnabled("revampedItemPCUI") then return false end
    ok,err=pcall(GoldCompat.drawGoldItemPc,top,
      love.graphics.getWidth(),love.graphics.getHeight())
  elseif kind=="save" then
    if not featureEnabled("revampedSaveUI") then return false end
    ok,err=pcall(GoldCompat.drawGoldSave,top)
  elseif kind=="options" then
    if not goldScreenEnabled("revampedOptionsUI") then return false end
    ok,err=pcall(GoldCompat.drawGen1OptionsHanging,top)
  elseif kind=="mods" then
    if not goldScreenEnabled("revampedModsUI") then return false end
    ok,err=pcall(GoldCompat.drawGen1ModManagerHanging,top)
  elseif kind=="trainer" then
    if not goldScreenEnabled("revampedTrainerCardUI") then return false end
    ok,err=pcall(GoldCompat.drawGen2TrainerCardHanging,top)
  elseif kind=="ui-settings" then
    ok,err=pcall(GoldCompat.drawGoldUISettings,top)
  else
    return false
  end

  if not ok and mod.log then
    mod.log:error("Gen 3 UI Gold overlay failed ("..tostring(kind).."): "..tostring(err))
  end
  return ok and true or false
end

function GoldCompat.renderHudMenuLayer(mod,game)
  -- Gen 1 level-up StatBox is a pushed battle UI state. Render its modern
  -- card here, after the battlefield, while leaving native A/B dismissal and
  -- queue sequencing completely untouched.
  if GoldCompat.generation=="gen1" and State.activeGen1LevelUpBox then
    local top=topState(game)
    if top==State.activeGen1LevelUpBox
        and (featureEnabled("revampedLevelUpUI")
          or GoldCompat.strictBattleUiForGame(game)) then
      local ok,err=pcall(GoldCompat.drawGen1LevelUpBox,
        State.activeGen1LevelUpBox)
      if not ok and mod.log then
        mod.log:error("Gen 1 level-up box failed: "..tostring(err))
      end
      return ok
    else
      State.activeGen1LevelUpBox=nil
    end
  end

  -- Gen 1 Options / Mods / Trainer Card use the same hanging-over-overworld
  -- ownership model as START. Native states keep all input and actions.
  if GoldCompat.generation=="gen1" then
    local top=topState(game)

    if State.activeGen1Options then
      if top==State.activeGen1Options
          and featureEnabled("revampedOptionsUI") then
        local ok,err=pcall(GoldCompat.drawGen1OptionsHanging,
          State.activeGen1Options)
        if not ok and mod.log then
          mod.log:error("Gen 1 hanging Options failed: "..tostring(err))
        end
        return ok
      else
        State.activeGen1Options=nil
      end
    end

    if State.activeGen1Mods then
      if top==State.activeGen1Mods
          and featureEnabled("revampedModsUI") then
        local ok,err=pcall(GoldCompat.drawGen1ModManagerHanging,
          State.activeGen1Mods)
        if not ok and mod.log then
          mod.log:error("Gen 1 hanging Mod Manager failed: "..tostring(err))
        end
        return ok
      else
        State.activeGen1Mods=nil
      end
    end

    if State.activeGen1TrainerCard then
      if top==State.activeGen1TrainerCard
          and featureEnabled("revampedTrainerCardUI") then
        local ok,err=pcall(GoldCompat.drawGen1TrainerCardHanging,
          State.activeGen1TrainerCard)
        if not ok and mod.log then
          mod.log:error("Gen 1 hanging Trainer Card failed: "..tostring(err))
        end
        return ok
      else
        State.activeGen1TrainerCard=nil
      end
    end
  end

  -- Gold service overlays are intentionally drawn here, after the overworld
  -- pass, exactly like the working Gen 1 START overlay.
  if GoldCompat.renderGoldServiceOverlay(mod,game) then return true end

  -- START / Bag draw after the palettized screen pass, like Party.
  if State.activeStartMenu and uiTopState(game, State.activeStartMenu) then
    local okStart, errStart = pcall(GoldCompat.drawStartFinal, game, State.activeStartMenu)

    -- Gold START display uses a copied label table only; restore engine-owned
    -- items immediately so selection/actions never operate on presentation data.
    if GoldCompat.generation=="gen2"
        and State.activeStartMenu.__gen3uiOriginalItems then
      State.activeStartMenu.items=State.activeStartMenu.__gen3uiOriginalItems
    end

    if okStart and GoldCompat.generation=="gen2"
        and State.activeStartMenu.phase=="confirm" then
      pcall(GoldCompat.drawGoldStartConfirm,State.activeStartMenu)
    end
    if (not okStart) and mod.log then
      mod.log:error("Gen 3 Inspired UI Overhaul START renderer failed: "..tostring(errStart))
    end
    return true
  elseif State.activeStartMenu then
    State.activeStartMenu = nil
  end

  if State.activeBagMenu and uiTopState(game, State.activeBagMenu) then
    local okBag, errBag = pcall(drawBagFinal, game, State.activeBagMenu)
    if (not okBag) and mod.log then
      mod.log:error("Gen 3 Inspired UI Overhaul Bag renderer failed: "..tostring(errBag))
    end
    return true
  elseif State.activeBagMenu then
    State.activeBagMenu = nil
  end

  -- STATS / MOVES use the engine's native SummaryMenu state and input.
  -- Only its presentation is replaced here.
  if DexUI.summary then
    if topState(game)==DexUI.summary
        and (featureEnabled("revampedPokemonMenu")
          or GoldCompat.strictBattleUiForGame(game)) then
      local okSummary,errSummary=pcall(DexUI.drawPartySummary,game,DexUI.summary)
      if not okSummary and mod.log then
        mod.log:error("Gen 3 UI Summary renderer failed: "..tostring(errSummary))
      end
      return true
    elseif not stateExistsInStack(game,DexUI.summary) then
      DexUI.summary=nil
    end
  end

  -- Draw Party after the palettized screen pass, preserving true neutral colors.
  if State.activeParty and partyTopState(game, State.activeParty) then
    local okParty, errParty = pcall(drawPartyFinal, game, State.activeParty)
    if (not okParty) and mod.log then
      mod.log:error("Gen 3 Inspired UI Overhaul party renderer failed: "..tostring(errParty))
    end
    return true
  elseif State.activeParty and partyShouldRenderBehindTM(game, State.activeParty) then
    -- Kept-open TM/HM Party backgrounds are already drawn at the beginning
    -- of render.hud so dialogue/teach overlays can safely render on top.
    State.activeTMParty = State.activeParty
  elseif State.activeParty then
    if State.activeItemTargetParty==State.activeParty
        and not partyInStack(game,State.activeParty) then
      State.activeItemTargetParty=nil
    end
    State.activeParty = nil
  end


  return false
end

function GoldCompat.renderHudBattleLayer(mod,game)
  -- Battle-only pushed UI states own the foreground, but should still feel
  -- like part of the current battle rather than dropping back to classic boxes.
  local pushedBattle=battleStateInStack(game)
  local topForBattle=topState(game)

  if State.activeBattleMoveLearn
      and topForBattle==State.activeBattleMoveLearn
      and pushedBattle
      and battleUiPresentationEnabled() then
    local cmd=commandGeometry()
    local s=hudScale()
    pcall(function()
      if shouldDrawStatusHUD(game,pushedBattle) then
        drawEnemyHUD(pushedBattle,s)
        drawPlayerHUD(pushedBattle,s,cmd)
      end
    end)
    local ok,err=pcall(drawBattleMoveLearnFinal,pushedBattle,State.activeBattleMoveLearn)
    if (not ok) and mod.log then
      mod.log:error("Gen 3 UI battle MoveLearn renderer failed: "..tostring(err))
    end
    return true
  elseif State.activeBattleMoveLearn and not stateExistsInStack(game,State.activeBattleMoveLearn) then
    State.activeBattleMoveLearn=nil
  end

  local battle = State.activeBattle
  if not battleUiPresentationEnabled() then
    State.activeBattle = nil
    return true
  end
  if not battleInStack(game, battle) then
    State.activeBattle = nil
    return true
  end

  -- If Bag / Party / Summary / another pushed state owns the foreground,
  -- preserve State.activeBattle but draw none of our battle UI over that screen.
  if not battleOwnsForeground(game, battle) then
    return true
  end

  local visualBattle=GoldCompat.presentBattleState(battle)
  local cmd = commandGeometry()
  local s = hudScale()

  -- Preserve intro / replacement party-count information hidden with the
  -- native HUD. This is presentation only; battle party data stays native.
  -- Status HUD remains visible for normal battle messages and the main
  -- FIGHT/POKEMON/BAG/RUN prompt, but yields the screen to full move select.
  love.graphics.push("all")
  local okStatus, errStatus = pcall(function()
    if shouldDrawStatusHUD(game, visualBattle) then
      drawEnemyHUD(visualBattle, s)
      drawPlayerHUD(visualBattle, s, cmd)
    end
  end)
  love.graphics.pop()

  love.graphics.push("all")
  local okUI, errUI = pcall(function()
    drawDialogue(visualBattle)
    drawCommandMenu(visualBattle)
    drawMoveSelect(visualBattle)
  end)
  love.graphics.pop()

  if mod.log then
    if not okStatus then
      mod.log:error("Gen 3 Inspired UI Overhaul status HUD failed: "..tostring(errStatus))
    end
    if not okUI then
      mod.log:error("Gen 3 Inspired UI Overhaul battle UI failed: "..tostring(errUI))
    end
  end
  return false
end

local function renderHudHook(mod,next,game,viewport)
  next(game,viewport)
  if not (love and love.graphics) then return end

  if GoldCompat.renderHudUnderlays(mod,game) then return end
  if GoldCompat.renderHudDialogueLayer(mod,game) then return end
  if GoldCompat.renderHudMenuLayer(mod,game) then return end
  GoldCompat.renderHudBattleLayer(mod,game)
end

-- -------------------------------------------------------------------------
-- Missing-screen parity layer
-- -------------------------------------------------------------------------
-- This module is intentionally additive. Existing battle, Party, Summary,
-- Bag, PC, Pokédex, Mart, Save, Options, Trainer Card and Pokégear renderers
-- above remain authoritative and are not recolored, wrapped or redirected.
-- Only screen classes which previously had no Gen 3 presentation are claimed.
GoldCompat.FeatureParity=(function()
  local P={mod=nil,classKinds={},titleStarted=nil,location={}}

  P.optionSpecs={
    -- Was gen="gen1"-only on the assumption Gen 2 already had a complete,
    -- working dedicated renderer (GoldCompat.drawGoldItemPc via ItemPcMenu)
    -- -- confirmed by user report that Gen 2's Item PC storage flow is still
    -- fully vanilla, so that assumption was wrong (or at least incomplete).
    -- No longer gen-restricted, so this both shows as a toggle and actually
    -- takes effect on Gen 2 saves too -- see P.patchItemPC below.
    {key="revampedItemPCUI",label="ITEM STORAGE PC UI",default=true},
    {key="revampedStarterUI",label="STARTER CONFIRMATION UI",default=true},
    {key="revampedNamingUI",label="NAMING SCREEN UI",default=true},
    {key="revampedSafariUI",label="SAFARI ZONE UI",default=true},
    {key="revampedEvolutionUI",label="EVOLUTION / EGG UI",default=true},
    -- Held items don't exist in Gen 1 at all, and the only class this option
    -- ever gates (src.ui.gen2.HeldItemMenu) is patched exclusively inside the
    -- generation=="gen2" branch below -- this showed as a live-looking toggle
    -- on Gen 1 that did nothing. Tagged gen2-only so it's not dead weight.
    {key="revampedHeldItemUI",label="HELD ITEM UI",default=true,gen="gen2"},
    {key="revampedLocationBannerUI",label="AREA BANNER UI",default=true},
    {key="revampedClockUI",label="CLOCK SETUP UI",default=true,gen="gen2"},
    {key="revampedServiceMenusUI",label="SERVICE / EVENT MENUS",default=true,gen="gen2"},
    {key="revampedMailUI",label="MAIL UI",default=true,gen="gen2"},
    {key="revampedBankUI",label="MOM'S BANK UI",default=true,gen="gen2"},
    {key="revampedDayCareUI",label="DAY CARE UI",default=true,gen="gen2"},
    {key="revampedElevatorUI",label="ELEVATOR UI",default=true,gen="gen2"},
    {key="revampedDecorationUI",label="DECORATION UI",default=true,gen="gen2"},
    {key="revampedPrizeUI",label="PRIZE MENU UI",default=true,gen="gen2"},
    {key="revampedContestUI",label="CONTEST UI",default=true,gen="gen2"},
    {key="revampedMoveDeleterUI",label="MOVE DELETER UI",default=true,gen="gen2"},
    {key="revampedScriptMenuUI",label="SCRIPT CHOICE UI",default=true,gen="gen2"},
    {key="revampedTradeUI",label="TRADE UI",default=true,gen="gen2"},
    {key="revampedPhotoStudioUI",label="PHOTO STUDIO UI",default=true,gen="gen2"},
    {key="revampedUnownPrinterUI",label="UNOWN PRINTER UI",default=true,gen="gen2"},
    {key="revampedHallOfFameUI",label="HALL OF FAME UI",default=true,gen="gen2"},
    {key="revampedDiplomaUI",label="DIPLOMA UI",default=true,gen="gen2"},
    {key="revampedMapRadioUI",label="MAP / RADIO UI",default=true,gen="gen2"},
    -- Kept opt-in so the already-working native title is unchanged by default.
    {key="revampedTitleIntro",label="GEN 3 TITLE REVEAL",default=false},
  }

  P.kindOptions={
    ["item-pc"]="revampedItemPCUI",
    ["held-item"]="revampedHeldItemUI",
    mail="revampedMailUI", mailbox="revampedMailUI",
    ["mail-read"]="revampedMailUI",["mail-compose"]="revampedMailUI",
    bank="revampedBankUI",daycare="revampedDayCareUI",
    elevator="revampedElevatorUI",decoration="revampedDecorationUI",
    prize="revampedPrizeUI",contest="revampedContestUI",
    ["move-deleter"]="revampedMoveDeleterUI",
    ["script-menu"]="revampedScriptMenuUI",
    trade="revampedTradeUI",["trade-animation"]="revampedTradeUI",
    photo="revampedPhotoStudioUI",unown="revampedUnownPrinterUI",
    ["hall-of-fame"]="revampedHallOfFameUI",diploma="revampedDiplomaUI",
    clock="revampedClockUI",["name-pick"]="revampedNamingUI",
    ["map-radio"]="revampedMapRadioUI",naming="revampedNamingUI",
    evolution="revampedEvolutionUI",["egg-hatch"]="revampedEvolutionUI",
  }

  P.serviceKinds={
    mail=true,mailbox=true,["mail-read"]=true,["mail-compose"]=true,
    bank=true,daycare=true,elevator=true,decoration=true,prize=true,
    contest=true,["move-deleter"]=true,["script-menu"]=true,trade=true,
    ["trade-animation"]=true,photo=true,unown=true,["hall-of-fame"]=true,
    diploma=true,["map-radio"]=true,
  }

  P.titles={
    ["item-pc"]="ITEM STORAGE",["held-item"]="HELD ITEM",
    mail="MAIL",mailbox="MAILBOX",["mail-read"]="READ MAIL",
    ["mail-compose"]="WRITE MAIL",bank="MOM'S BANK",daycare="DAY-CARE",
    elevator="ELEVATOR",decoration="DECORATION",prize="PRIZE EXCHANGE",
    contest="BUG-CATCHING CONTEST",["move-deleter"]="MOVE DELETER",
    ["script-menu"]="SELECTION",trade="TRADE CENTER",
    ["trade-animation"]="POKéMON TRADE",photo="PHOTO STUDIO",
    unown="UNOWN REPORT",["hall-of-fame"]="HALL OF FAME",
    diploma="DIPLOMA",clock="SET THE CLOCK",["name-pick"]="CHOOSE A NAME",
    ["map-radio"]="POKéGEAR RADIO",naming="NAME ENTRY",
    evolution="EVOLUTION",["egg-hatch"]="EGG HATCH",
  }

  function P.enabled(kind)
    -- HIDE NATIVE BATTLE UI is a master battle-surface guarantee, not merely
    -- another aesthetic toggle. If one of these engine-owned auxiliary states
    -- (MoveDeleter, naming/evolution handoff, etc.) is stacked over a live
    -- battle, force its already-supported themed renderer on even when that
    -- individual screen toggle is off. Outside battle every per-screen option
    -- remains completely independent.
    if GoldCompat.strictBattleUiForGame(P.mod and P.mod.game) then return true end
    local key=P.kindOptions[kind] or kind
    if P.serviceKinds[kind] and not featureEnabled("revampedServiceMenusUI") then
      return false
    end
    return featureEnabled(key)
  end

  function P.defineOptions(mod)
    local defs={}
    for _,spec in ipairs(P.optionSpecs) do
      if not spec.gen or spec.gen==GoldCompat.generation then
        defs[#defs+1]={key=spec.key,type="toggle",label=spec.label,
          default=spec.default}
      end
    end
    if #defs>0 then mod.options:define(defs) end

    local existing={}
    for _,row in ipairs(DexUI.uiRows or {}) do existing[row.key]=true end
    for _,spec in ipairs(P.optionSpecs) do
      if (not spec.gen or spec.gen==GoldCompat.generation) and not existing[spec.key] then
        table.insert(DexUI.uiRows,{key=spec.key,label=spec.label,kind="toggle"})
        existing[spec.key]=true
      end
    end
  end

  function P.fit(text,size,minSize,sc,maxWidth)
    local value=tostring(text or "")
    local out=size
    while out>minSize and finalTextWidth(value,out,sc)>maxWidth do
      out=out-0.12
    end
    return out
  end

  function P.screen(title,subtitle)
    local ox,oy,sc=safeFullCanvas()
    local G=love.graphics
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    -- Exact material vocabulary of the established Gen 3 Summary/Party pages.
    G.setColor(0.94,0.93,0.87,1); G.rectangle("fill",0,0,160,144)
    G.setColor(0.08,0.08,0.08,1); G.rectangle("fill",4,4,152,17)
    G.setColor(0.99,0.985,0.955,1); G.rectangle("fill",5,5,150,15)
    G.setColor(0.12,0.12,0.11,1); roundedRect("fill",5,25,150,103,3)
    G.setColor(0.99,0.985,0.95,1); roundedRect("fill",7,27,146,99,2)
    setCurrentBorderColor(1); roundedRect("line",8,28,144,97,2)
    G.setColor(0.08,0.08,0.07,1); G.rectangle("fill",4,132,152,8)
    G.pop()
    finalText(title or "MENU",9,8,4.5,{0.06,0.06,0.06,1},ox,oy,sc,
      "left",104)
    if subtitle and subtitle~="" then
      finalText(subtitle,112,10,P.fit(subtitle,2.1,1.3,sc,38),
        {0.34,0.34,0.31,1},ox,oy,sc,"right",38)
    end
    return ox,oy,sc
  end

  -- The field a native flow keeps its row list under varies per screen and
  -- isn't documented anywhere this mod's source can see -- this mod has no
  -- visibility into Gen1Recomp's own ElevatorMenu/DecorationMenu/etc source,
  -- so every plausible name is tried rather than assuming one. A screen
  -- whose native rows live under a name not in this list still falls
  -- through to the "no rows" branch exactly as before -- this only adds new
  -- ways to find a non-empty table, never changes a match that already
  -- worked.
  local PARITY_ROW_KEYS={"rows","entries","items","categories","prizes",
    "team","party","moves","floors","destinations","stations",
    "options","choices","picks"}

  local function findRowsIn(t)
    if type(t)~="table" then return nil end
    for _,key in ipairs(PARITY_ROW_KEYS) do
      local rows=t[key]
      if type(rows)=="table" and #rows>0 then return rows end
    end
    return nil
  end

  function P.rows(flow)
    local direct=findRowsIn(flow)
    if direct then return direct end
    for _,key in ipairs({"list","menu","picker","floorMenu","floorList"}) do
      local nested=flow and flow[key]
      if type(nested)=="table" then
        local found=findRowsIn(nested)
        if found then return found end
        if type(nested.items)=="table" and #nested.items>0 then return nested.items end
        if #nested>0 then return nested end
      end
    end
    return {}
  end

  function P.rowLabel(row)
    if type(row)=="string" or type(row)=="number" then return tostring(row) end
    if type(row)~="table" then return "" end
    local value=row.label or row.name or row.text or row.item or row.species or row.id
    if type(value)=="function" then
      local ok,result=pcall(value,row); if ok then value=result end
    end
    if type(value)=="table" then value=value.name or value.label or value.id end
    value=tostring(value or "")
    if row.label==nil and row.name==nil and row.text==nil then
      value=value:gsub("_+"," "):gsub("%-+"," "):gsub("(%l)(%u)","%1 %2")
    end
    if row.count then value=value.."  ×"..tostring(row.count) end
    if row.price then value=value.."  ¥"..tostring(row.price) end
    return value
  end

  function P.index(flow)
    return math.max(1,tonumber(flow and (flow.index or flow.listIndex or
      flow.cursor or flow.row or flow.optionIndex or flow.modeIndex or
      flow.selected or flow.selectedIndex or flow.floor)) or 1)
  end

  function P.message(flow)
    local value=flow and (flow.message or flow.confirm or flow.lines or flow.prompt
      or (flow.entry and (flow.entry.message or flow.entry.text or flow.entry.lines))
      or flow.status)
    if type(value)=="table" then
      if value.pages then value=value.pages[value.page or 1] end
      if type(value)=="table" then value=table.concat(value," ") end
    end
    return GoldCompat.cleanWrappedText(tostring(value or ""))
  end

  function P.itemPCOwner(game)
    if GoldCompat.generation~="gen1" then return nil end
    local states=game and game.stack and game.stack.states or {}
    for i=#states,1,-1 do
      local state=states[i]
      if state and state.__gen3uiParityKind=="item-pc" then return state end
    end
    return nil
  end

  function P.drawGen1ItemPC(flow,overlay)
    if not flow then return false end
    local ox,oy,sc=finalCanvas()
    local G=love.graphics
    local phase=tostring(flow.__gen3uiItemPCPhase or "menu")
    local x,y,w,h=20,7,120,130

    local function clean(value)
      value=GoldCompat.cleanWrappedText(tostring(value or ""))
      return value:gsub("<NEXT>"," "):gsub("[\r\n\f\v]+"," "):gsub("%s+"," ")
    end
    local function promptCard(text)
      local px,py,pw,ph=x+7,y+91,w-14,24
      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      G.setColor(0.90,0.89,0.82,1); roundedRect("fill",px,py,pw,ph,2)
      G.setColor(0.72,0.70,0.62,1); roundedRect("line",px,py,pw,ph,2)
      G.pop()
      text=clean(text)
      if text=="" then text="Choose an item." end
      local f=font(math.max(8,math.floor(2.55*sc*UI_TEXT_SCALE*GoldCompat.userTextScale()+0.5)))
      local _,wrapped=f:getWrap(text,(pw-12)*sc)
      for i=1,math.min(2,#wrapped) do
        GoldCompat.panelText(wrapped[i],px+6,py+5+(i-1)*7,2.55,
          {0.08,0.08,0.07,1},"left",pw-12)
      end
    end

    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.04,0.04,0.04,0.34); roundedRect("fill",x+2,y+2,w,h,4)
    G.setColor(0.08,0.08,0.07,1); roundedRect("fill",x,y,w,h,4)
    G.setColor(0.99,0.985,0.95,1); roundedRect("fill",x+2,y+2,w-4,h-4,3)
    drawUnifiedBorder(x,y,w,h,1)
    G.setColor(0.11,0.28,0.38,1); roundedRect("fill",x+5,y+5,w-10,15,2)
    G.setColor(0.92,0.47,0.13,1); G.rectangle("fill",x+8,y+18,w-16,1.5)
    G.setColor(0.08,0.08,0.07,1); roundedRect("fill",x+5,y+h-13,w-10,9,2)
    G.pop()

    GoldCompat.panelText("ITEM STORAGE",x+10,y+9,4.0,{1,1,1,1})
    local phaseLabel=phase=="withdraw" and "WITHDRAW"
      or phase=="deposit" and "DEPOSIT"
      or phase=="toss" and "TOSS" or "PLAYER'S PC"
    GoldCompat.panelText(phaseLabel,x+w-45,y+10,2.2,{0.84,0.90,0.88,1},"right",33)

    local rows=flow.items or {}
    local selected=math.max(1,tonumber(flow.index) or 1)
    if phase=="menu" then
      local rowH=GoldCompat.dynamicRowHeight(2.8,10,3)
      rowH=math.min(rowH,14)
      local listY=y+30
      local listH=math.max(42,math.min(58,#rows*rowH+6))
      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      G.setColor(0.90,0.89,0.82,1); roundedRect("fill",x+8,listY,w-16,listH,2)
      G.setColor(0.72,0.70,0.62,1); roundedRect("line",x+8,listY,w-16,listH,2)
      G.pop()
      for i,row in ipairs(rows) do
        local yy=listY+4+(i-1)*rowH
        local active=i==selected
        if active then
          G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
          G.setColor(0.10,0.10,0.09,1); roundedRect("fill",x+12,yy-1,w-24,rowH-1,1.4)
          G.setColor(0.92,0.47,0.13,1); roundedRect("fill",x+13,yy+2,2,math.max(4,rowH-6),0.7)
          G.pop()
        end
        GoldCompat.panelText(clean(row and row.label),x+19,yy+1,2.8,
          active and {1,1,1,1} or {0.06,0.06,0.06,1},"left",w-34)
      end
      promptCard("What do you want to do?")
    else
      local total=#rows
      local rowH=GoldCompat.dynamicRowHeight(3.0,11,3)
      rowH=math.min(rowH,15)
      local listY=y+27
      local available=60
      local visible=math.max(2,math.min(4,math.floor(available/rowH)))
      local first=(tonumber(flow.scroll) or 0)+1
      if selected<first then first=selected end
      if selected>first+visible-1 then first=selected-visible+1 end
      first=math.max(1,math.min(first,math.max(1,total-visible+1)))

      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      G.setColor(0.90,0.89,0.82,1); roundedRect("fill",x+7,listY,w-14,available+4,2)
      G.setColor(0.72,0.70,0.62,1); roundedRect("line",x+7,listY,w-14,available+4,2)
      G.pop()

      for r=1,visible do
        local idx=first+r-1
        local row=rows[idx]
        if not row then break end
        local yy=listY+4+(r-1)*rowH
        local active=idx==selected
        if active then
          G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
          G.setColor(0.10,0.10,0.09,1); roundedRect("fill",x+10,yy-1,w-20,rowH-1,1.4)
          G.setColor(0.92,0.47,0.13,1); roundedRect("fill",x+11,yy+2,2,math.max(4,rowH-6),0.7)
          G.pop()
        end
        local label=clean(row.label or row.name or row.value or "ITEM")
        GoldCompat.panelText(label,x+17,yy+1,3.0,
          active and {1,1,1,1} or {0.06,0.06,0.06,1},"left",70)
        if row.count then
          GoldCompat.panelText("×"..tostring(row.count),x+w-31,yy+1,2.65,
            active and {1,1,1,1} or {0.28,0.28,0.25,1},"right",17)
        end
      end
      promptCard(flow.footer or (phase=="deposit" and "What do you want to deposit?"
        or phase=="withdraw" and "What do you want to withdraw?"
        or "What do you want to toss away?"))
    end

    -- QuantityBox and ChoiceBox are pushed ABOVE the PlayerPC list. Their
    -- native state/input remains untouched; this only repaints the foreground
    -- controls so the flow never flashes back to cartridge chrome.
    if overlay and getmetatable(overlay)==QuantityBox then
      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      G.setColor(0.11,0.28,0.38,1); roundedRect("fill",x+w-42,y+95,31,15,2)
      G.pop()
      GoldCompat.panelText(("×%02d"):format(tonumber(overlay.qty) or 1),
        x+w-38,y+99,3.0,{1,1,1,1},"center",23)
    elseif overlay and getmetatable(overlay)==ChoiceBox then
      local c=math.max(1,math.min(2,tonumber(overlay.index) or 1))
      local qx,qy=x+w-43,y+91
      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      G.setColor(0.90,0.89,0.82,1); roundedRect("fill",qx,qy,35,24,2)
      for i=1,2 do
        if i==c then
          G.setColor(0.10,0.10,0.09,1); roundedRect("fill",qx+3,qy+2+(i-1)*10,29,9,1)
        end
      end
      G.pop()
      GoldCompat.panelText("YES",qx+8,qy+4,2.35,c==1 and {1,1,1,1} or {0.08,0.08,0.08,1})
      GoldCompat.panelText("NO",qx+8,qy+14,2.35,c==2 and {1,1,1,1} or {0.08,0.08,0.08,1})
    end

    local footer=(overlay and getmetatable(overlay)==QuantityBox) and "↑/↓ AMOUNT   A CONFIRM   B BACK"
      or (overlay and getmetatable(overlay)==ChoiceBox) and "↑/↓ CHOOSE   A CONFIRM   B BACK"
      or phase=="menu" and "A CONFIRM   B BACK"
      or "↑/↓ SELECT   A CONFIRM   B BACK"
    GoldCompat.panelText(footer,x+10,y+h-11,1.65,{0.98,0.98,0.96,1},"left",w-20)
    return true
  end

  function P.drawGeneric(flow,kind)
    local rows=P.rows(flow)
    if #rows==0 and kind=="held-item" and not flow.message and not flow.confirm then
      rows={{label="GIVE"},{label="TAKE"}}
    end
    local selected=P.index(flow)
    local subtitle=tostring(flow.phase or flow.mode or ""):upper()
    local ox,oy,sc=P.screen(P.titles[kind] or "MENU",subtitle)
    local G=love.graphics
    local first=math.max(1,math.min(selected-2,math.max(1,#rows-6+1)))
    local visible=math.min(6,#rows)

    if visible>0 then
      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      G.setColor(0.90,0.89,0.82,1); roundedRect("fill",13,34,134,66,2)
      G.setColor(0.70,0.68,0.59,1); roundedRect("line",13,34,134,66,2)
      for line=1,visible do
        local index=first+line-1
        local yy=38+(line-1)*10
        if index==selected then GoldCompat.frlgSelection(16,yy-2,128,9) end
      end
      G.pop()

      for line=1,visible do
        local index=first+line-1
        local label=P.rowLabel(rows[index])
        local yy=39+(line-1)*10
        finalText(label,22,yy,P.fit(label,2.8,1.65,sc,112),
          index==selected and {1,1,1,1} or {0.08,0.08,0.08,1},
          ox,oy,sc,"left",112)
      end
    else
      local value=flow.text or flow.stationName or flow.pendingDeco or flow.mode
        or flow.phase or "PLEASE WAIT..."
      finalText(tostring(value):upper(),20,54,
        P.fit(tostring(value):upper(),3.2,1.65,sc,120),
        {0.16,0.16,0.14,1},ox,oy,sc,"left",120)
      if kind=="trade-animation" then
        finalText("Trading Pokémon",20,66,2.5,{0.38,0.38,0.35,1},ox,oy,sc)
      elseif kind=="hall-of-fame" then
        finalText("Registering the winning team",20,66,2.35,
          {0.38,0.38,0.35,1},ox,oy,sc)
      end
    end

    local message=P.message(flow)
    if message~="" then
      local f=font(math.max(8,math.floor(2.4*sc*UI_TEXT_SCALE+0.5)))
      local _,wrapped=f:getWrap(message,126*sc)
      for i=1,math.min(2,#wrapped) do
        finalText(wrapped[i],17,106+(i-1)*7,2.35,
          {0.16,0.16,0.14,1},ox,oy,sc,"left",126)
      end
    end
    local confirm=flow.confirm
    if type(confirm)=="table" then
      local choice=math.max(1,math.min(2,tonumber(confirm.choice) or 1))
      local G=love.graphics
      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      for i=1,2 do
        local xx=45+(i-1)*39
        if i==choice then GoldCompat.frlgSelection(xx,115,34,10) end
      end
      G.pop()
      finalText("YES",49,117,2.35,choice==1 and {1,1,1,1}
        or {0.08,0.08,0.08,1},ox,oy,sc,"center",26)
      finalText("NO",88,117,2.35,choice==2 and {1,1,1,1}
        or {0.08,0.08,0.08,1},ox,oy,sc,"center",26)
    elseif type(flow.qtyState)=="table" then
      local qty=tonumber(flow.qtyState.quantity or flow.qtyState.qty
        or flow.qtyState.value) or 1
      finalText("QUANTITY  ×"..tostring(qty),44,116,2.55,
        {0.08,0.08,0.08,1},ox,oy,sc,"center",72)
    end
    finalText(visible>0 and "↑/↓ SELECT   A CONFIRM   B BACK" or "B: BACK",
      10,134,1.8,{0.96,0.95,0.90,1},ox,oy,sc,"left",140)
  end

  function P.namingGrid(flow)
    local ok,rows
    if type(flow.grid)=="function" then ok,rows=pcall(flow.grid,flow)
    elseif type(flow.rows)=="function" then ok,rows=pcall(flow.rows,flow) end
    return ok and type(rows)=="table" and rows or {}
  end

  function P.drawNaming(flow,kind)
    local fallback=(kind=="mail-compose") and "WRITE MAIL" or "NAME ENTRY"
    local ox,oy,sc=P.screen(tostring(flow.title or fallback),"GEN 3 KEYBOARD")
    local G=love.graphics
    local rows=P.namingGrid(flow)
    local gen1=type(flow.glyphs)=="table"
    local row=gen1 and (tonumber(flow.row) or 1) or ((tonumber(flow.row) or 0)+1)
    local col=gen1 and (tonumber(flow.col) or 1) or ((tonumber(flow.col) or 0)+1)
    local value=gen1 and table.concat(flow.glyphs or {})
      or tostring(flow.text or flow.pendingName or "")
    local maxLen=tonumber(flow.maxLen or flow.maxLength) or 7

    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.11,0.28,0.38,1); roundedRect("fill",14,31,132,14,2)
    G.setColor(0.99,0.985,0.95,1); roundedRect("fill",16,33,128,10,1)
    G.setColor(0.86,0.87,0.84,1); roundedRect("fill",12,50,136,66,3)
    G.setColor(0.12,0.12,0.11,1); roundedRect("line",12,50,136,66,3)
    G.pop()

    finalText(value~="" and value or "_",21,35,3.4,{0.06,0.06,0.06,1},
      ox,oy,sc,"left",92)
    finalText(("%d/%d"):format(#value,maxLen),123,36,2.2,
      {0.34,0.34,0.31,1},ox,oy,sc,"right",17)

    local shown=math.min(5,#rows)
    for r=1,shown do
      local cells=rows[r] or {}
      local count=math.max(1,#cells)
      local cellW=126/math.max(9,count)
      local yy=56+(r-1)*11
      for c=1,#cells do
        local x=17+(c-1)*cellW
        local active=r==row and c==col
        if active then
          G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
          GoldCompat.frlgSelection(x-1,yy-2,cellW,9)
          G.pop()
        end
        local label=tostring(cells[c] or " ")
        if label==" " then label="SP" end
        finalText(label,x,yy,#label>1 and 1.8 or 2.65,
          active and {1,1,1,1} or {0.08,0.08,0.08,1},
          ox,oy,sc,"center",cellW-1)
      end
    end
    if not gen1 and (tonumber(flow.row) or 0)>=#rows then
      local nativeCol=tonumber(flow.col) or 0
      local active=nativeCol<3 and 1 or (nativeCol<6 and 2 or 3)
      local labels={flow.lower and "UPPER" or "LOWER","DEL","END"}
      local xs={17,66,105}; local ws={43,33,38}
      for i,label in ipairs(labels) do
        if i==active then
          G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
          GoldCompat.frlgSelection(xs[i]-2,104,ws[i],10)
          G.pop()
        end
        finalText(label,xs[i],106,1.9,i==active and {1,1,1,1}
          or {0.08,0.08,0.08,1},ox,oy,sc,"center",ws[i]-4)
      end
    end
    finalText("A ENTER   B DELETE   START OK",10,134,1.8,
      {0.96,0.95,0.90,1},ox,oy,sc,"left",140)
  end

  function P.spriteProxy(mon,species)
    local proxy={species=species}
    for key,value in pairs(mon or {}) do proxy[key]=value end
    proxy.species=species
    return proxy
  end

  function P.drawEvolution(flow,egg)
    local game=flow.game
    local ox,oy,sc=P.screen(egg and "EGG HATCH" or "EVOLUTION",
      tostring(flow.phase or "IN PROGRESS"):upper())
    local oldSpecies=flow.__gen3uiOldSpecies or flow.oldSpecies
      or (flow.mon and flow.mon.species)
    local newSpecies=flow.newSpecies or flow.species
      or (flow.evolved and flow.evolved.species)
    local showNew=flow.showNew
    if showNew==nil and flow.t then
      local elapsed=tonumber(flow.t) or 0
      local period=math.max(4,28-math.floor(elapsed/40)*6)
      showNew=math.floor(elapsed/period)%2==1
    end
    if flow.done and not flow.canceled then showNew=true end
    if egg then showNew=flow.showMon==true end

    local G=love.graphics
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.84,0.90,0.78,1); roundedRect("fill",18,34,124,68,4)
    G.setColor(0.11,0.28,0.38,1); roundedRect("line",18,34,124,68,4)
    G.setColor(0.70,0.82,0.58,0.65); G.ellipse("fill",80,91,42,8)
    G.setColor(0.95,0.36,0.17,1); G.rectangle("fill",34,105,92,2)
    G.pop()

    if egg and not showNew then
      G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
      G.setColor(0.98,0.98,0.90,1); G.ellipse("fill",80,66,15,24)
      G.setColor(0.24,0.50,0.30,1)
      G.circle("fill",73,59,3); G.circle("fill",87,67,3.5); G.circle("fill",78,77,2.5)
      G.pop()
    else
      local species=(showNew and newSpecies) or oldSpecies or newSpecies
      local mon=showNew and (flow.evolved or flow.mon) or flow.mon
      G.push("all"); G.origin()
      pcall(GoldCompat.drawCleanResolvedPortrait,game,P.spriteProxy(mon,species),
        ox+48*sc,oy+42*sc,64*sc,50*sc,"evolution")
      G.pop()
    end
    local message=P.message(flow)
    if message=="" then
      local name=(flow.mon and (flow.mon.nickname or flow.mon.name)) or "POKéMON"
      message=egg and (tostring(name).." is hatching!")
        or ("What? "..tostring(name).." is evolving!")
    end
    finalText(message,18,112,P.fit(message,2.5,1.65,sc,124),
      {0.12,0.12,0.11,1},ox,oy,sc,"center",124)
    finalText((not egg and not flow.done) and "B: CANCEL" or "PLEASE WAIT...",
      10,134,1.8,{0.96,0.95,0.90,1},ox,oy,sc)
  end

  function P.drawClock(flow)
    local phase=tostring(flow.phase or "hour"):lower()
    local isDay=flow.mode=="day" or phase=="day"
    local ox,oy,sc=P.screen(isDay and "SET THE DAY" or "SET THE CLOCK","POKéGEAR")
    local hour=tonumber(flow.hour or flow.hours or flow.h) or 12
    local minute=tonumber(flow.minute or flow.minutes or flow.m) or 0
    local h12=hour%12
    if h12==0 then h12=12 end
    local timeLabel=("%d:%02d %s"):format(h12,minute,hour>=12 and "PM" or "AM")
    local question=""
    if type(flow.question)=="function" then
      local ok,value=pcall(flow.question,flow)
      if ok and value then question=tostring(value) end
    end
    if question=="" then question=P.message(flow) end
    question=GoldCompat.cleanWrappedText(question)
    local display=nil
    if type(flow.display)=="function" then
      local ok,value=pcall(flow.display,flow)
      if ok and value~=nil then display=tostring(value):upper() end
    end
    if phase=="hour" or phase=="minute" then display=timeLabel end
    local confirming=false
    if type(flow.confirming)=="function" then
      local ok,value=pcall(flow.confirming,flow)
      confirming=ok and value==true
    end
    local G=love.graphics
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.11,0.28,0.38,1); roundedRect("fill",20,42,120,51,4)
    G.setColor(0.99,0.985,0.95,1); roundedRect("fill",24,46,112,43,3)
    G.pop()

    if question~="" then
      finalText(question,27,50,P.fit(question,2.2,1.35,sc,106),
        {0.22,0.22,0.20,1},ox,oy,sc,"center",106)
    end

    if confirming then
      local selected=math.max(1,math.min(2,tonumber(flow.yesNo) or 1))
      for i,label in ipairs({"YES","NO"}) do
        local x=35+(i-1)*49
        G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
        if i==selected then GoldCompat.frlgSelection(x,68,41,15) end
        G.pop()
        finalText(label,x+6,72,3.0,
          i==selected and {1,1,1,1} or {0.08,0.08,0.08,1},
          ox,oy,sc,"center",29)
      end
      finalText("←/→ CHOOSE",46,100,2.1,{0.20,0.20,0.18,1},ox,oy,sc,"center",68)
    elseif display then
      finalText("▲",74,62,2.2,{0.95,0.36,0.17,1},ox,oy,sc,"center",12)
      finalText(display,30,69,P.fit(display,5.3,2.7,sc,100),
        {0.08,0.08,0.08,1},ox,oy,sc,"center",100)
      finalText("▼",74,83,2.2,{0.95,0.36,0.17,1},ox,oy,sc,"center",12)
      finalText("↑/↓ OR ←/→ ADJUST",34,100,1.9,
        {0.20,0.20,0.18,1},ox,oy,sc,"center",92)
    else
      finalText("A CONTINUE",48,70,2.8,{0.11,0.28,0.38,1},ox,oy,sc,"center",64)
    end

    local footer=(phase=="intro" or phase=="response") and "A CONTINUE"
      or (confirming and "A CONFIRM   B BACK" or "A SELECT   B BACK")
    finalText(footer,10,134,P.fit(footer,1.8,1.35,sc,140),
      {0.96,0.95,0.90,1},ox,oy,sc,"center",140)
  end

  function P.kindFor(state)
    if not state or state.__gen3uiParityFailed then return nil end
    return state.__gen3uiParityKind or P.classKinds[getmetatable(state)]
  end

  function P.battleBelow(state)
    local game=state and state.game
    local states=game and game.stack and game.stack.states or {}
    for i=#states,1,-1 do
      local candidate=states[i]
      if candidate~=state and (candidate==State.activeBattle
          or getmetatable(candidate)==BattleState
          or GoldCompat.isGen2BattleState(candidate)) then return candidate end
    end
    return nil
  end

  function P.patchClass(moduleName,kind,captureSpecies)
    local ok,class=pcall(require,moduleName)
    if not ok or type(class)~="table" or class.__gen3uiParityPatched then return false end
    class.__gen3uiParityPatched=true
    P.classKinds[class]=kind
    local oldNew=class.new
    local oldOpaque=class.isOpaque
    local oldDraw=class.draw
    local oldWide=class.drawWidescreen
    local oldDraws=class.drawsWidescreen
    local oldFill=class.wantsFillScale
    local oldUpdate=class.update

    if type(oldNew)=="function" then
      class.new=function(...)
        local args={...}
        local state=oldNew(...)
        if type(state)=="table" then
          state.__gen3uiParityKind=kind
          if captureSpecies then
            local mon=type(args[2])=="table" and (args[2].mon or args[2]) or nil
            state.__gen3uiOldSpecies=state.oldSpecies or (mon and mon.species)
          end
          state.isOpaque=P.enabled(kind) and false or oldOpaque
        end
        return state
      end
    end

    class.draw=function(self,...)
      if P.enabled(kind) and not self.__gen3uiParityFailed then
        self.__gen3uiParityKind=kind; self.isOpaque=false
        -- Run native draw with a zero-size scissor instead of skipping it
        -- outright: some native flows only populate their own row list (or
        -- other per-frame state) inside draw() itself, and simply never
        -- calling it risks starving that -- the same class of bug already
        -- found and fixed for the Gen 2 battle HUD and for Options/Mods/
        -- Trainer Card/Save Menu earlier this session. Guarantees zero
        -- native pixels reach the frame either way.
        if type(oldDraw)=="function" then
          return runDrawInvisible(oldDraw,self,...)
        end
        return
      end
      self.isOpaque=oldOpaque
      if type(oldDraw)=="function" then return oldDraw(self,...) end
    end
    class.drawsWidescreen=function(self,...)
      if P.enabled(kind) and not self.__gen3uiParityFailed then
        return P.battleBelow(self)~=nil
      end
      if type(oldDraws)=="function" then return oldDraws(self,...) end
      return false
    end
    class.wantsFillScale=function(self,...)
      if P.enabled(kind) and not self.__gen3uiParityFailed then
        local battle=P.battleBelow(self)
        if battle and type(battle.wantsFillScale)=="function" then
          local okValue,value=pcall(battle.wantsFillScale,battle)
          if okValue then return value end
        end
        return false
      end
      if type(oldFill)=="function" then return oldFill(self,...) end
      return false
    end
    class.drawWidescreen=function(self,winW,winH,...)
      if P.enabled(kind) and not self.__gen3uiParityFailed then
        self.__gen3uiParityKind=kind; self.isOpaque=false
        local battle=P.battleBelow(self)
        if battle and type(battle.drawWidescreen)=="function" then
          return battle:drawWidescreen(winW,winH)
        end
        if type(oldWide)=="function" then
          return runDrawInvisible(oldWide,self,winW,winH,...)
        end
        return
      end
      self.isOpaque=oldOpaque
      if type(oldWide)=="function" then return oldWide(self,winW,winH,...) end
    end
    if kind=="clock" and type(oldUpdate)=="function" then
      class.update=function(self,dt,...)
        if P.enabled(kind) and not self.__gen3uiParityFailed then
          local input=self.game and self.game.input
          if input then
            local confirming=false
            if type(self.confirming)=="function" then
              local ok,value=pcall(self.confirming,self)
              confirming=ok and value==true
            end
            local more=false
            if type(self.morePages)=="function" then
              local ok,value=pcall(self.morePages,self)
              more=ok and value==true
            end
            if confirming and not more then
              if input:wasPressed("left") then self.yesNo=1; return
              elseif input:wasPressed("right") then self.yesNo=2; return end
            elseif self.phase=="hour" or self.phase=="minute" or self.phase=="day" then
              if input:wasPressed("left") and type(self.step)=="function" then
                self:step(-1); return
              elseif input:wasPressed("right") and type(self.step)=="function" then
                self:step(1); return
              end
            end
          end
        end
        return oldUpdate(self,dt,...)
      end
    end
    return true
  end

  function P.menuLabel(entry)
    return tostring(type(entry)=="table" and (entry.label or entry.name) or entry or ""):upper()
  end

  function P.patchItemPC()
    -- Gen 2 has a real dedicated ItemPcMenu adapter (drawGoldItemPc) and is
    -- already correct. Gen 1 is structurally different: src/ui/PlayerPC.lua
    -- builds the root with generic Menu, then pushes generic ListMenu states
    -- whose titles are NIL and whose identity is carried only by opts.kind:
    --   pc_item_withdraw / pc_item_deposit / pc_item_toss.
    -- The old recognizer looked only for title strings, so every Gen 1 item
    -- list missed the hook and rendered the exact vanilla screen seen in the
    -- user's screenshot. Keep this adapter Gen 1-only so the working Gen 2
    -- path cannot regress.
    if GoldCompat.generation~="gen1" then return end

    local ITEM_KINDS={
      pc_item_withdraw="withdraw",
      pc_item_deposit="deposit",
      pc_item_toss="toss",
    }

    if not Menu.__gen3uiParityItemPC then
      Menu.__gen3uiParityItemPC=true
      local oldMenuNew=Menu.new
      Menu.new=function(game,items,opts,...)
        local state=oldMenuNew(game,items,opts,...)
        local labels={}
        for i,item in ipairs(items or {}) do labels[i]=P.menuLabel(item) end
        if labels[1]=="WITHDRAW ITEM" and labels[2]=="DEPOSIT ITEM"
            and labels[3]=="TOSS ITEM" then
          state.__gen3uiParityKind="item-pc"
          state.__gen3uiItemPCPhase="menu"
          if P.enabled("item-pc") then state.isOpaque=false end
        end
        return state
      end

      -- Presentation-only suppression. The Menu object remains the native
      -- input/state owner; its pixels are simply hidden while our hanging
      -- Item Storage card is drawn in render.hud. runDrawInvisible preserves
      -- any future per-frame bookkeeping inside the native draw method.
      local oldMenuDraw=Menu.draw
      Menu.draw=function(self,...)
        if self.__gen3uiParityKind=="item-pc" and P.enabled("item-pc") then
          self.isOpaque=false
          if type(oldMenuDraw)=="function" then
            return runDrawInvisible(oldMenuDraw,self,...)
          end
          return
        end
        return oldMenuDraw(self,...)
      end
    end

    if not ListMenu.__gen3uiParityItemPC then
      ListMenu.__gen3uiParityItemPC=true
      local oldListNew=ListMenu.new
      ListMenu.new=function(game,title,items,opts,...)
        local state=oldListNew(game,title,items,opts,...)
        local kind=tostring((opts and opts.kind) or state.kind or "")
        local phase=ITEM_KINDS[kind]
        -- Exact Gen 1 PlayerPC kinds are authoritative. Keep the old title
        -- fallback for compatibility with older Gen1Recomp revisions/mods.
        local upper=tostring(title or ""):upper()
        if not phase then
          if upper=="WITHDRAW ITEM" then phase="withdraw"
          elseif upper=="DEPOSIT ITEM" then phase="deposit"
          elseif upper=="TOSS ITEM" then phase="toss" end
        end
        if phase then
          state.__gen3uiParityKind="item-pc"
          state.__gen3uiItemPCPhase=phase
          if P.enabled("item-pc") then state.isOpaque=false end
        end
        return state
      end

      local oldListDraw=ListMenu.draw
      ListMenu.draw=function(self,...)
        if self.__gen3uiParityKind=="item-pc" and P.enabled("item-pc") then
          self.isOpaque=false
          if type(oldListDraw)=="function" then
            return runDrawInvisible(oldListDraw,self,...)
          end
          return
        end
        return oldListDraw(self,...)
      end
    end
  end

  function P.starterSpecies(owner)
    local game=owner and owner.game
    local text={}
    for _,page in ipairs(owner and owner.pages or {}) do
      for _,line in ipairs(page or {}) do text[#text+1]=tostring(line) end
    end
    local all=table.concat(text," "):upper()
    if all:find("NICK",1,true) or all:find("RELEASE",1,true)
        or all:find("FORGET",1,true) or all:find("LEARN",1,true)
        or all:find("DELETE",1,true) then return nil end
    local chooseIntent=all:find("WANT",1,true) or all:find("TAKE",1,true)
      or all:find("CHOOSE",1,true) or all:find("STARTER",1,true)
    if not chooseIntent then return nil end
    local wanted={1,4,7,25,133,152,155,158}
    for id,def in pairs(game and game.data and game.data.pokemon or {}) do
      local dex=tonumber(def.dex)
      for _,candidate in ipairs(wanted) do
        if dex==candidate and all:find(tostring(def.name or ""):upper(),1,true) then
          return id,def
        end
      end
    end
    local targetDex=nil
    local gen2=GoldCompat.generation=="gen2"
    if all:find("FIRE",1,true) then targetDex=gen2 and 155 or 4
    elseif all:find("WATER",1,true) then targetDex=gen2 and 158 or 7
    elseif all:find("GRASS",1,true) or all:find("PLANT",1,true)
        or all:find("LEAF",1,true) then targetDex=gen2 and 152 or 1 end
    if targetDex then
      for id,def in pairs(game and game.data and game.data.pokemon or {}) do
        if tonumber(def.dex)==targetDex then return id,def end
      end
    end
    return nil
  end

  function P.drawStarter(choice,owner)
    local id=choice and choice.__gen3uiStarterSpecies
    local def=choice and choice.__gen3uiStarterDef
    if not id then id,def=P.starterSpecies(owner) end
    if not id then return false end
    local game=(owner and owner.game) or (choice and choice.game)
    local selected=tonumber(choice.index or choice.selected or choice.choice) or 1
    if selected==0 then selected=1 end
    local ox,oy,sc=P.screen("CHOOSE THIS POKéMON?","STARTER")
    local G=love.graphics
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.84,0.90,0.78,1); roundedRect("fill",17,34,64,72,4)
    G.setColor(0.11,0.28,0.38,1); roundedRect("line",17,34,64,72,4)
    G.setColor(0.90,0.89,0.82,1); roundedRect("fill",87,40,57,51,3)
    for i=1,2 do
      local yy=49+(i-1)*18
      if i==selected then GoldCompat.frlgSelection(92,yy-3,47,14) end
    end
    G.pop()
    G.push("all"); G.origin()
    pcall(GoldCompat.drawCleanResolvedPortrait,game,{species=id},
      ox+25*sc,oy+44*sc,48*sc,45*sc,"starter")
    G.pop()
    finalText(tostring(def.name or id),23,91,3.25,{0.08,0.08,0.08,1},
      ox,oy,sc,"center",52)
    for i,label in ipairs({"YES","NO"}) do
      finalText(label,105,51+(i-1)*18,3.3,
        i==selected and {1,1,1,1} or {0.08,0.08,0.08,1},
        ox,oy,sc,"center",25)
    end
    finalText("A CONFIRM   B BACK",10,134,1.8,{0.96,0.95,0.90,1},ox,oy,sc)
    return true
  end

  function P.claimStarter(game,choice)
    if not (featureEnabled("revampedStarterUI")
        and choice and getmetatable(choice)==ChoiceBox) then return nil end
    local states=game and game.stack and game.stack.states or {}
    local owner=states[#states-1]
    local id,def=P.starterSpecies(owner)
    if not id then
      choice.__gen3uiStarterSpecies=nil
      choice.__gen3uiStarterDef=nil
      choice.__gen3uiStarterOwner=nil
      return nil
    end
    choice.__gen3uiStarterSpecies=id
    choice.__gen3uiStarterDef=def
    choice.__gen3uiStarterOwner=owner
    return owner
  end

  function P.drawSafariBattle(battle)
    if not battle then return false end
    local source=battle.__gen3Source or battle
    local game=battle.game or (source and source.game)
    local safari=(type(battle.safari)=="table" and battle.safari)
      or (source and type(source.safari)=="table" and source.safari)
      or (game and game.save and type(game.save.safari)=="table" and game.save.safari)
    if not safari then return false end
    if battle.phase~="menu" then return false end
    local rect=commandGeometry()
    drawPanelBase(rect)
    local G=love.graphics
    local u=rect.u or battleMenuScale()
    local railW=math.min(rect.w*0.46,205*u)
    local railH=32*u
    local railY=math.max(8,rect.y-railH-9*u)
    G.setColor(0.02,0.03,0.04,0.38)
    roundedRect("fill",rect.x+5*u,railY+5*u,railW,railH,9*u)
    G.setColor(0.95,0.95,0.92,0.98)
    roundedRect("fill",rect.x,railY,railW,railH,8*u)
    G.setColor(0.16,0.30,0.42,1)
    roundedRect("line",rect.x+u,railY+u,railW-2*u,railH-2*u,7*u)
    printText("SAFARI",rect.x+10*u,railY+5*u,8*u,{0.12,0.14,0.16,1})
    printText("BALLS "..tostring(math.max(0,tonumber(safari.balls) or 0)),
      rect.x+72*u,railY+5*u,7*u,{0.12,0.14,0.16,1})
    printText("STEPS "..tostring(math.max(0,tonumber(safari.steps) or 0)),
      rect.x+72*u,railY+16*u,7*u,{0.34,0.34,0.31,1})
    local pad,gap=15*u,11*u
    local cellW=(rect.w-pad*2-gap)/2
    local cellH=(rect.h-pad*2-gap)/2
    local options={{1,"BALL",0,0},{2,"BAIT",1,0},{3,"ROCK",0,1},{4,"RUN",1,1}}
    for _,entry in ipairs(options) do
      local x=rect.x+pad+entry[3]*(cellW+gap)
      local y=rect.y+pad+entry[4]*(cellH+gap)
      local selected=(battle.menuIndex or 1)==entry[1]
      if selected then
        G.setColor(0.16,0.30,0.42,1); roundedRect("fill",x,y,cellW,cellH,10*u)
        G.setColor(0.95,0.36,0.17,1); roundedRect("fill",x+6*u,y+7*u,5*u,cellH-14*u,2*u)
      else
        G.setColor(0.86,0.87,0.84,1); roundedRect("fill",x,y,cellW,cellH,10*u)
        G.setColor(0.97,0.97,0.95,1); roundedRect("fill",x+2*u,y+2*u,cellW-4*u,cellH-4*u,8*u)
      end
      printText(entry[2],x+16*u,y+cellH*0.12,cellH*0.43,
        selected and {0.98,0.98,0.96,1} or {0.12,0.14,0.16,1},
        "center",cellW-24*u)
    end
    return true
  end

  function P.drawSafariField(game)
    local safari=game and game.save and game.save.safari
    if type(safari)~="table" or battleStateInStack(game) then return false end
    local ox,oy,sc=finalCanvas()
    local G=love.graphics
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.08,0.08,0.07,0.95); roundedRect("fill",5,5,62,22,3)
    G.setColor(0.99,0.985,0.95,0.98); roundedRect("fill",7,7,58,18,2)
    G.setColor(0.11,0.28,0.38,1); roundedRect("line",7,7,58,18,2)
    G.pop()
    finalText("SAFARI ZONE",11,9,2.0,{0.08,0.08,0.08,1},ox,oy,sc)
    finalText("BALLS "..tostring(math.max(0,tonumber(safari.balls) or 0)),
      11,16,1.75,{0.30,0.30,0.28,1},ox,oy,sc)
    finalText("STEPS "..tostring(math.max(0,tonumber(safari.steps) or 0)),
      36,16,1.75,{0.30,0.30,0.28,1},ox,oy,sc)
    return true
  end

  function P.mapName(game)
    local world=game and (game.overworld or game.world or game.field)
    local map=world and (world.map or world.currentMap)
    local raw=(type(map)=="table" and (map.landmarkName or map.displayName or map.name or map.id))
      or (world and (world.mapName or world.mapId))
    if not raw then return nil end
    if type(map)=="table" and map.outdoor==false then return nil end
    local rawUpper=tostring(raw):upper()
    for _,word in ipairs({"HOUSE","ROOM","MART","CENTER","GYM","LAB",
        "OFFICE","ELEVATOR","SHOP"}) do
      if rawUpper:find(word,1,true) then return nil end
    end
    local text=tostring(raw):gsub("_"," "):gsub("(%l)(%u)","%1 %2")
    return text:gsub("(%a)(%d)","%1 %2"):upper()
  end

  function P.drawLocation(game)
    -- One-time diagnostic: this mod's own location banner is purely additive
    -- (it has never located, let alone suppressed, any native banner-drawing
    -- class -- there is no such reference anywhere in this file), which is
    -- why the native banner still shows alongside it. Without Gen1Recomp's
    -- engine source there is no way to know what that native class/field is
    -- called, so log every "banner"/"location"/"area name"-ish field found on
    -- the live game/world tables once, so the real name can be targeted next
    -- round instead of guessed at blind.
    if not P.__bannerDiagLogged then
      P.__bannerDiagLogged=true
      local ok=pcall(function()
        local hits={}
        local function scan(t,label)
          if type(t)~="table" then return end
          for k,v in pairs(t) do
            local ks=tostring(k):lower()
            if ks:find("banner",1,true) or ks:find("location",1,true)
                or ks:find("areaname",1,true) or ks:find("area_name",1,true)
                or ks:find("sign",1,true) or ks:find("landmark",1,true)
                or ks:find("townmsg",1,true) or ks:find("mapmsg",1,true)
                or ks:find("mapname",1,true) then
              hits[#hits+1]=label.."."..tostring(k).."="..tostring(v)
            end
          end
        end
        scan(game,"game")
        scan(game and (game.overworld or game.world or game.field),"world")
        if P.mod and P.mod.log then
          if #hits>0 then
            P.mod.log:info("Gen 3 UI banner diag: "..table.concat(hits," | "))
          else
            P.mod.log:info("Gen 3 UI banner diag: no banner/location-ish "
              .."fields found on game/world tables")
          end
        end
      end)
      if not ok and P.mod and P.mod.log then
        P.mod.log:error("Gen 3 UI banner diag failed to run")
      end
    end

    if battleStateInStack(game) then return false end
    local name=P.mapName(game)
    if not name then return false end
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    if name~=P.location.last then
      P.location.last=name; P.location.started=now
    end
    local elapsed=now-(P.location.started or now)
    if elapsed>3.2 then return false end
    local alpha=math.min(1,elapsed/0.28,(3.2-elapsed)/0.45)
    local ox,oy,sc=finalCanvas()
    local width=math.max(60,math.min(120,finalTextWidth(name,2.8,sc)+20))
    local G=love.graphics
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.08,0.08,0.07,0.88*alpha); roundedRect("fill",5,5,width,18,3)
    G.setColor(0.99,0.985,0.95,0.96*alpha); roundedRect("fill",7,7,width-4,14,2)
    G.setColor(0.95,0.36,0.17,alpha); G.rectangle("fill",10,19,width-10,1.5)
    G.pop()
    finalText(name,12,10,P.fit(name,2.8,1.7,sc,width-18),
      {0.08,0.08,0.08,alpha},ox,oy,sc,"left",width-18)
    return true
  end

  function P.renderHud(next,game,viewport)
    -- Claim the exact starter ChoiceBox before the lower-priority dialogue
    -- renderer runs. This prevents the same native choice from being rendered
    -- once as a generic side menu and again as the starter confirmation screen.
    local before=topState(game)
    if before and getmetatable(before)==ChoiceBox then
      P.claimStarter(game,before)
    end
    next(game,viewport)
    if not (love and love.graphics) then return end
    local top=topState(game)

    -- Gen 1 PlayerPC is built from generic Menu/ListMenu plus transient
    -- QuantityBox/ChoiceBox states. The actual item-PC owner may therefore
    -- sit one or two states below the top. Repaint the nearest tagged owner
    -- every frame before generic parity dispatch so nested quantity/toss
    -- confirmation never exposes vanilla chrome. Gen 2 deliberately skips
    -- this path and keeps its already-working dedicated ItemPcMenu renderer.
    if GoldCompat.generation=="gen1" and P.enabled("item-pc") then
      local itemPc=P.itemPCOwner(game)
      if itemPc then
        local ok,err=pcall(P.drawGen1ItemPC,itemPc,top)
        if not ok and P.mod and P.mod.log then
          P.mod.log:error("Gen 3 Gen1 Item PC renderer failed: "..tostring(err))
        end
        if ok then return end
      end
    end

    local kind=P.kindFor(top)
    -- Gen 2's forget-a-move step (src/ui/gen2/MoveDeleter.lua,
    -- opts.layout=="forget") is this exact "move-deleter" generic screen
    -- when it's the standalone Blackthorn NPC or an Ether/Elixir PP-restore
    -- picker -- but when it's the TM/HM/level-up forget step for the mon
    -- currently open in our own reskinned party card (State.activeGen2MoveLearn,
    -- wired up in installCoreMenuUI), that card's own REPLACE MOVE panel
    -- already owns the visual instead (State.activeGen2MoveDeleter). Skip
    -- the generic themed box only for that specific case so the two
    -- presentations never draw on top of each other.
    if kind=="move-deleter" and top and top.forget
        and State.activeGen2MoveLearn
        and State.activeGen2MoveLearn.mon==top.mon then
      kind=nil
    end
    if kind and P.enabled(kind) then
      local ok,err=pcall(function()
        if kind=="naming" or kind=="mail-compose" then P.drawNaming(top,kind)
        elseif kind=="evolution" then P.drawEvolution(top,false)
        elseif kind=="egg-hatch" then P.drawEvolution(top,true)
        elseif kind=="clock" then P.drawClock(top)
        else P.drawGeneric(top,kind) end
      end)
      if not ok then
        top.__gen3uiParityFailed=true
        top.isOpaque=true
        if P.mod and P.mod.log then
          P.mod.log:error("Gen 3 missing-screen renderer failed ("..tostring(kind).."): "..tostring(err))
        end
      end
      return
    end

    if featureEnabled("revampedStarterUI") and getmetatable(top)==ChoiceBox then
      local owner=top.__gen3uiStarterOwner or P.claimStarter(game,top)
      local ok,drew=pcall(P.drawStarter,top,owner)
      if ok and drew then return end
    end

    local battle=State.activeBattle
    if featureEnabled("revampedSafariUI") and battle and battleInStack(game,battle) then
      local visual=GoldCompat.presentBattleState(battle)
      local ok,drew=pcall(P.drawSafariBattle,visual)
      if ok and drew then return end
    end
    if featureEnabled("revampedSafariUI") then pcall(P.drawSafariField,game) end
    local menuOwnsForeground=top and (
      GoldCompat.supportedOverworldMenuState(top)
      or getmetatable(top)==TextBox or getmetatable(top)==ChoiceBox
      or getmetatable(top)==NamingScreen)
    if featureEnabled("revampedLocationBannerUI") and not menuOwnsForeground then
      pcall(P.drawLocation,game)
    end
  end

  function P.patchTitle(moduleName)
    local ok,class=pcall(require,moduleName)
    if not ok or type(class)~="table" or class.__gen3uiParityTitle then return end
    class.__gen3uiParityTitle=true
    local function overlay(state)
      if not featureEnabled("revampedTitleIntro") then return end
      local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
      state.__gen3uiTitleStarted=state.__gen3uiTitleStarted or now
      local t=now-state.__gen3uiTitleStarted
      if t>2.2 then return end
      local sw,sh=love.graphics.getDimensions()
      local a=math.min(1,t/0.3,(2.2-t)/0.45)
      local G=love.graphics
      G.push("all"); G.origin()
      G.setColor(0.04,0.10,0.20,0.72*a); G.rectangle("fill",0,0,sw,sh)
      local r=math.min(sw,sh)*0.095
      local cx,cy=sw*0.5,sh*0.48
      G.setColor(0.88,0.17,0.12,a); G.arc("fill",cx,cy,r,math.pi,math.pi*2)
      G.setColor(0.98,0.98,0.92,a); G.arc("fill",cx,cy,r,0,math.pi)
      G.setColor(0.05,0.08,0.14,a); G.rectangle("fill",cx-r,cy-2,r*2,4)
      G.circle("fill",cx,cy,r*0.25)
      G.setColor(0.98,0.98,0.92,a); G.circle("fill",cx,cy,r*0.12)
      G.pop()
      printText("GEN 3 UI",sw*0.5-120,cy+r+18,30,{1,1,1,a},"center",240)
    end
    if type(class.drawWidescreen)=="function" then
      local old=class.drawWidescreen
      class.drawWidescreen=function(self,...)
        local result={old(self,...)}; overlay(self); return unpack(result)
      end
    elseif type(class.draw)=="function" then
      local old=class.draw
      class.draw=function(self,...)
        local result={old(self,...)}; overlay(self); return unpack(result)
      end
    end
  end

  function P.install(mod)
    P.mod=mod
    P.defineOptions(mod)
    GoldCompat.invalidateOptionCache()
    P.patchItemPC()
    P.patchClass("src.ui.EvolutionState","evolution",true)
    P.patchClass("src.ui.NamingScreen","naming",false)
    if GoldCompat.generation=="gen2" then
      local flows={
        {"src.ui.gen2.HeldItemMenu","held-item"},{"src.ui.gen2.MailMenu","mail"},
        {"src.ui.gen2.MailboxMenu","mailbox"},{"src.ui.gen2.MailRead","mail-read"},
        {"src.ui.gen2.MailCompose","mail-compose"},{"src.ui.gen2.BankOfMom","bank"},
        {"src.ui.gen2.DayCareMenu","daycare"},{"src.ui.gen2.ElevatorMenu","elevator"},
        {"src.ui.gen2.DecorationMenu","decoration"},{"src.ui.gen2.PrizeMenu","prize"},
        {"src.ui.gen2.ContestMenu","contest"},{"src.ui.gen2.MoveDeleter","move-deleter"},
        {"src.ui.gen2.ScriptMenu","script-menu"},{"src.ui.gen2.TradeMenu","trade"},
        {"src.ui.gen2.TradeAnim","trade-animation"},{"src.ui.gen2.PhotoStudio","photo"},
        {"src.ui.gen2.UnownPrinter","unown"},{"src.ui.gen2.HallOfFame","hall-of-fame"},
        {"src.ui.gen2.Diploma","diploma"},{"src.ui.gen2.InitClock","clock"},
        {"src.ui.gen2.NamePick","name-pick"},{"src.ui.gen2.MapRadio","map-radio"},
        {"src.ui.gen2.NamingScreen","naming"},
        {"src.ui.gen2.EvolutionAnim","evolution",true},
        {"src.ui.gen2.EggHatchAnim","egg-hatch",true},
      }
      for _,entry in ipairs(flows) do P.patchClass(entry[1],entry[2],entry[3]) end
    end
    P.patchTitle("src.ui.TitleState")
    P.patchTitle("src.ui.gen2.TitleState")
    mod.hooks:wrap("render.hud",P.renderHud,10500)
  end

  return P
end)()

local Installers = {}
Installers.installVerifiedOptions = installVerifiedOptions
Installers.installPCIntegration = installPCIntegration
Installers.installMartUI = installMartUI
Installers.installGen1SaveScreen = installGen1SaveScreen
Installers.installDialogueThemeDirect = installDialogueThemeDirect
Installers.handleModOptionChanged = handleModOptionChanged
Installers.patchVanillaTextDrawing = patchVanillaTextDrawing
Installers.installOverworldUI = installOverworldUI
Installers.installGoldBattlePresentation = GoldCompat.installGoldBattlePresentation

return function(mod)
  GoldCompat.mod=mod
  local liveGame=mod and mod.game or nil
  GoldCompat.generation=GoldCompat.isGen2Game(liveGame) and "gen2" or "gen1"
  if mod.log then
    mod.log:info("Gen 3 UI runtime compatibility: "..tostring(GoldCompat.generation))
  end

  Installers.installVerifiedOptions(mod)
  spritePortraitResolver.install(mod)

  -- The 1.3.2 renderers below patch Gen 1 concrete menu classes. On Gold,
  -- preserve the complete native Gen 2 Pack/Party/Summary/PC/Pokédex/Mart and
  -- dialogue flows rather than landing dead or shape-incompatible patches.
  -- Gold-specific themed surfaces are added only where the shared API supplies
  -- a trustworthy cross-generation seam.
  if GoldCompat.generation=="gen1" then
    Installers.installPCIntegration()
    Installers.installMartUI()
    Installers.installGen1SaveScreen()
  else
    GoldCompat.installGen2MenuFadeCompat()
  end

  -- Gold uses the shared TextBox / ChoiceBox path for overworld dialogue.
  -- This is a genuine cross-generation seam, so reuse the proven Gen 3
  -- dialogue presentation instead of leaving Gold dialogue vanilla.
  Installers.installDialogueThemeDirect(mod)
  if mod.events and mod.events.on then
    mod.events:on("mod.options_changed", function(payload)
      Installers.handleModOptionChanged(mod,payload)
    end)

    if GoldCompat.generation=="gen2" then
      mod.events:on("battle.fainted", function(payload)
        local battle=payload and payload.battle
        local side=payload and payload.side
        local enemyFainted=side and side.index==2
        if enemyFainted and battle and battle.player then
          local mon=battle.player
          mon.gen3uiFainted=(tonumber(mon.gen3uiFainted) or 0)+1
        end
      end)
    end
  end
  -- Battle Arts 1.8+ exposes an official presentation contract and already
  -- recognises gen3_battle_ui by mod ID. When present, let Battle Arts itself
  -- suppress its native HUD/text/panels. We do NOT wrap its BattleState draw
  -- functions, snapHUDs, hudTexture, drawHudPanels, BattleArt, or sprite path.
  local baHandle=nil
  if mod.find then
    for _,id in ipairs({"BATTLE_ART_VOXEL_GEN2","BATTLE_ART_VOXEL_FORK"}) do
      local okFind,candidate=pcall(mod.find,id)
      if okFind and candidate then baHandle=candidate break end
    end
  end
  local baPresentation = baHandle and baHandle.exports
      and baHandle.exports.battlePresentation or nil
  local baNativeContract = baPresentation
      and tonumber(baPresentation.apiVersion or 0) >= 1

  -- Battle Art draws through a compositor after the engine methods below.
  -- Its suppressHook is Battle Art's own all-or-nothing "hide your entire
  -- presentation" switch, which covers its custom sprite/model rendering as
  -- well as its HUD chrome -- there is no separate hook to ask it to keep
  -- drawing Pokemon art while only hiding its status/text panels. Gating this
  -- on ownsNativeBattleLayer() silently suppressed Battle Art's sprites for
  -- every default install, because that predicate is also true whenever the
  -- default-on BATTLE UI toggle (revampedBattleUI) is enabled, not just the
  -- explicit HIDE NATIVE BATTLE UI hard-suppress toggle this hook exists for.
  -- Only forward suppression when the user opted into hiding ALL native
  -- battle presentation; otherwise Battle Art (and any compatible sprite
  -- provider) keeps rendering its artwork, per ARCHITECTURE.md's sprite
  -- ownership contract ("must not silently replace Battle Arts... or other
  -- configured sprite providers").
  if baNativeContract and type(baPresentation.suppressHook)=="string"
      and mod.hooks and type(mod.hooks.wrap)=="function" then
    mod.hooks:wrap(baPresentation.suppressHook,function(next,request)
      local battle=type(request)=="table"
        and (request.battle or request.state or request.source) or nil
      if GoldCompat.hidesAllNativeBattlePresentation(battle) then return true end
      return next(request)
    end,12000)
  end

  -- Launcher API visibility is the first line of defense. Method wrappers and
  -- the compositor contracts remain as compatibility fallbacks for older or
  -- late-loading renderers.
  if mod.hooks and type(mod.hooks.wrap)=="function" then
    mod.hooks:wrap("battle.bottom_ui_visible",function(next,state)
      if GoldCompat.ownsNativeBattleLayer(state) then return false end
      return next(state)
    end,12000)
    mod.hooks:wrap("battle.status_hud_visible",function(next,state)
      if GoldCompat.ownsNativeBattleLayer(state) then return false end
      return next(state)
    end,12000)

    -- Both engines' BattleState:moveGridNavigation() (src/battle/BattleState.lua
    -- and src/ui/gen2/BattleState.lua) already call this exact hook to decide
    -- whether up/down/left/right should navigate the move menu as a 2x2 grid
    -- (native's own WideBattle widescreen layout uses the same hook point).
    -- Piggyback on it for the MOVE MENU LAYOUT setting's 2x2 GRID option so
    -- input matches what drawMoveSelectGrid actually draws -- only while our
    -- own battle UI (and that layout) is what's on screen; leave native's
    -- default vertical-list navigation alone otherwise.
    mod.hooks:wrap("battle.move_grid_navigation",function(next,state)
      if battleUiPresentationEnabled()
          and GoldCompat.battleMoveLayout()=="grid" then
        return true
      end
      return next(state)
    end,12000)
  end

  mod.exports=mod.exports or {}
  mod.exports.uiOwnership={
    apiVersion=3,
    ownsBattleUi=function(state)
      return GoldCompat.ownsNativeBattleLayer(state)
    end,
    nativeBattleUiVisible=function(state)
      return not GoldCompat.ownsNativeBattleLayer(state)
    end,
    -- Provider-facing invariant: when true, no caller should draw original
    -- Gen1Recomp battle HUD/text/menu chrome, even if it owns the world frame.
    hardHideNativeBattleUi=function(state)
      return GoldCompat.hidesAllNativeBattlePresentation(state)
    end,
    presentation="final-ui-layer",
  }

  -- Install native lifecycle-preserving suppression on classic/non-BA paths.
  -- The hard HIDE NATIVE BATTLE UI option also needs this wrapper available
  -- even when another presentation mod owns normal suppression.
  Installers.patchVanillaTextDrawing()
  if baNativeContract and mod.log then
    mod.log:info("Gen 3 UI: using Battle Arts 1.8 native presentation contract")
  end

  GoldCompat.installBattleUiFirewall()
  GoldCompat.patchShapeHudCompat(mod,"DRAMALESS_SHAPE","dramaless","Dramaless Shape")
  GoldCompat.patchShapeHudCompat(mod,"DRAMATIC_SHAPE","dramatic","Dramatic Shape 1.8")
  GoldCompat.stepAsideForCbeColosseumModels(mod)

  if mod.events and type(mod.events.on)=="function" then
    local function reassertBattleFirewall(payload)
      local battle=payload and (payload.battle or payload.state)
      if battle then State.activeBattle=battle end
      GoldCompat.refreshFullFrameCandidates(mod)
      GoldCompat.installBattleUiFirewall()
      GoldCompat.patchShapeHudCompat(mod,"DRAMALESS_SHAPE","dramaless","Dramaless Shape")
      GoldCompat.patchShapeHudCompat(mod,"DRAMATIC_SHAPE","dramatic","Dramatic Shape 1.8")
      -- Idempotent (see the marker inside): harmless to call again every
      -- battle, and catches the case where game.save wasn't populated yet
      -- the first time this ran at mod init.
      GoldCompat.stepAsideForCbeColosseumModels(mod)
    end
    mod.events:on("mods.loaded",reassertBattleFirewall,-20000)
    mod.events:on("battle.started",reassertBattleFirewall,-20000)
  end

  -- Dramaless/Dramatic HUD compatibility is handled exclusively by
  -- GoldCompat.patchShapeHudCompat above. Older builds wrapped the same
  -- OverworldBattle methods a second time here with a weaker predicate; that
  -- duplicate layer added per-frame calls and could override the generic
  -- full-frame-provider defer rule. The idempotent capability firewall is the
  -- single compatibility owner now.

  if GoldCompat.generation=="gen1" then
    Installers.installOverworldUI(mod)
    GoldCompat.installGen1ModernScreens()
  else
    GoldCompat.installCoreMenuUI()
    GoldCompat.installGoldServiceUI()
    GoldCompat.installPokegearUI()
    Installers.installGoldBattlePresentation()
  end

  GoldCompat.suppressNativeLocationBanner(mod)

  -- Add only the screens absent from the established Gen 3 presentation.
  -- Existing battle, party, summary, bag, PC, Pokédex, mart and save/options
  -- renderers above remain the sole owners of their already-working flows.
  GoldCompat.FeatureParity.install(mod)

  -- Native START-menu extension seam: insert UI immediately before OPTION.
  mod.hooks:wrap("ui.start_menu.items", function(next,game,items)
    local out=next(game,items)
    if type(out)~="table" then return items end

    for _,entry in ipairs(out) do
      if tostring(entry.label or ""):upper()=="UI" then return out end
    end

    local at=#out+1
    for i,entry in ipairs(out) do
      if tostring(entry.label or ""):upper()=="OPTION" then
        at=i
        break
      end
    end
    local row={
      label="UI",
      keepOpen=true,
      __gen3uiUIEntry=true,
    }
    if GoldCompat.isGen2Game(game) then
      row.onSelect=function(g) GoldCompat.openGoldUISettings(g or game) end
    end
    table.insert(out,at,row)
    return out
  end,500)

  -- Add a read-only MOVES shortcut beside STATS in the field Party submenu.
  -- Existing generic MOVES entries are normalized instead of duplicated.
  mod.hooks:wrap("ui.party.submenu", function(next,game,items,mon,ctx)
    local out=next(game,items,mon,ctx)
    -- Gold's native party submenu already owns STATS, held items/mail, field
    -- moves and its own move-management paths. Do not inject the Gen 1
    -- SummaryMenu shortcut into that richer menu.
    if GoldCompat.isGen2Game(game) then return out end
    if not featureEnabled("revampedPokemonMenu")
        or (ctx and ctx.battle)
        or type(out)~="table" then
      return out
    end

    local function openMoves(target,g)
      local SummaryMenu=require("src.ui.SummaryMenu")
      local summary=SummaryMenu.new(g,target)
      summary.page=2
      g.stack:push(summary)
    end

    local statsIndex=nil
    local movesIndex=nil
    for i,entry in ipairs(out) do
      local label=tostring(entry and entry.label or ""):upper()
      if label=="STATS" then statsIndex=i end
      if label=="MOVES" then movesIndex=i end
    end

    if movesIndex then
      -- Generic MOVES is informational in this UI: preserve the surrounding
      -- submenu but route it through the same native SummaryMenu page.
      out[movesIndex].action=nil
      out[movesIndex].onSelect=openMoves
    else
      local entry={label=Strings("MOVES"),onSelect=openMoves}
      table.insert(out,(statsIndex and statsIndex+1) or (#out+1),entry)
    end
    return out
  end, 500)

  mod.hooks:wrap("battle.overlay", battleOverlayHook, 9000)
  mod.hooks:wrap("render.hud", function(next,game,viewport)
    return renderHudHook(mod,next,game,viewport)
  end, 10000)

  mod.hooks:wrap("render.hud", DexUI.hud, 11000)

end
