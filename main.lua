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
  activeBattleStatBox = nil,
  activeShopMenu = nil,
  activeShopList = nil,
  activeShopQuantity = nil,
}


local modRef = nil
local GoldCompat = {
  enabled = false,
  game = nil,
  adapter = nil,
  generation = "gen1",
}

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
        local okMon,Mon=pcall(require,"src.battle.gen2.Mon")
        if okMon and Mon and type(Mon.gender)=="function" then
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
    ba = nil,
    baV = nil,
    baSets = {},
  }

  local function settingValue(setting)
    if setting and type(setting.get) == "function" then
      local ok, value = pcall(setting.get, setting)
      if ok then return value end
    end
    return nil
  end

  local function connectBattleArts()
    if R.ba and R.baV then return R.ba, R.baV end
    local mod = R.mod
    if not (mod and mod.find) then return nil end

    local okHandle, handle = pcall(mod.find, "BATTLE_ART_VOXEL_FORK")
    if not (okHandle and handle and type(handle.exports) == "table") then
      return nil
    end

    local V = handle.exports.lib
    if type(V) ~= "table" or type(V.require) ~= "function" then return nil end

    local okBA, BA = pcall(V.require, "BattleArt")
    if not (okBA and type(BA) == "table") then return nil end

    R.ba, R.baV = BA, V
    return BA, V
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

  local function battleArtsPortrait(mon)
    local BA, V = connectBattleArts()
    if not (BA and V and mon and mon.species) then return nil end

    local mode = settingValue(BA.setting)
    if mode == "rom" then return nil end

    local species = mon.species
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

    -- Battle Arts' MODDED mode only owns a picture when its matching shiny
    -- override exists; otherwise normal pokemon.sprite ownership wins.
    if type(BA.prefersModded) == "function" then
      local okModded, modded = pcall(BA.prefersModded)
      if okModded and modded then
        if mode == "animated" and tostring(generation or ""):match("^gen[1-5]$") then
          return preparedRelative(
            "assets/battle/front-animated/shiny/" .. generation .. "/" .. name .. ".png")
        elseif mode == "static" then
          return preparedRelative(
            "assets/battle/front-static/shiny/" .. name .. ".png")
        end
        return nil
      end
    end

    if mode == "static" then
      return preparedRelative("assets/battle/front-static/" .. name .. ".png")
    end

    if mode ~= "animated" then return nil end
    if not tostring(generation or ""):match("^gen[1-5]$") then return nil end

    if generation == "gen1" then
      return preparedRelative(
        "assets/battle/front-animated/gen1/" .. name .. ".png")
    end

    return battleArtsAnimatedFrame(BA, V, species, generation)
  end

  local function enginePalette(data, species, mon)
    -- Gold's normal front sprites are grayscale source art plus the species'
    -- native two-color battle palette. Use the same Gen 2 palette resolver
    -- the battle renderer uses, instead of the Gen 1/SGB mon palette helper.
    if GoldCompat.generation=="gen2" then
      local okPal,Palettes=pcall(require,"src.world.gen2.Palettes")
      -- IMPORTANT: Gold's Pokémon battle palettes live in game.data.gen2Palettes.
      -- This is the exact table src/ui/gen2/BattleState.lua stores as
      -- self.palettes before calling Palettes.monColors().
      local paletteData=data and data.gen2Palettes
      local colors=okPal and Palettes
        and type(Palettes.monColors)=="function"
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
    if vanillaPath and path ~= vanillaPath then
      trueColor = true
    end

    local palName, colors = enginePalette(data, mon.species, mon)
    local key = "engine:" .. path .. ":" .. (trueColor and "truecolor" or palName)
    local cached = R.cache[key]
    if cached ~= nil then
      return cached or nil, trueColor and true or false
    end

    local image
    if trueColor or not colors or not (love.image and love.image.newImageData) then
      image = Assets_.image(path)
    else
      local data = Assets_.imageData(path)
      if data then
        data:mapPixel(function(_,_,r,g,b,a)
          if a == 0 then return r,g,b,a end
          local col = r > 0.83 and colors[1]
            or r > 0.5 and colors[2]
            or r > 0.17 and colors[3]
            or colors[4]
          return col[1]/255, col[2]/255, col[3]/255, a
        end)
        image = love.graphics.newImage(data)
      end
    end

    if image and image.setFilter then image:setFilter("nearest","nearest") end
    R.cache[key] = image or false
    return image, trueColor and true or false
  end

  function R.install(mod)
    R.mod = mod
    connectBattleArts()
    return true
  end

  function R.resolve(game, mon, kind)
    if not (game and game.data and mon and mon.species) then return nil end

    -- All front-art consumers use the SAME precedence as battle. If Battle
    -- Arts currently owns the front sprite, menus/PC/Pokédex use that exact
    -- image too. Otherwise fall through to the live pokemon.sprite resolver.
    -- This keeps presentation-only UI synchronized with the player's equipped
    -- sprite package instead of inventing a separate menu-art source.
    local BA = R.ba
    local image = battleArtsPortrait(mon)
    if image then
      -- Battle Arts already records the alpha-visible bounds for every image
      -- prepared through BattleArt.prepareData(). Pass those bounds to the UI
      -- so portrait sizing is based on the Pokemon itself instead of the
      -- surrounding transparent canvas. This is especially important for the
      -- Gen 4 collection, where authored canvas occupancy varies by species.
      local meta
      local mode = BA and settingValue(BA.setting)
      local generation = BA and settingValue(BA.frontAnimationSetting)
      if mode == "animated" and generation == "gen4"
          and BA and type(BA.metrics) == "function" then
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

    local image,trueColor=enginePortrait(game,mon,kind)
    return image, image and {trueColor=trueColor and true or false} or nil
  end

  return R
end)()

local function clearBattleUIState()
  State.activeBattle=nil
  State.activeBattleMoveLearn=nil
  State.activeBattleMoveParty=nil
  State.activeBattleStatBox=nil
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
local UI_TEXT_WEIGHT_OFFSET = 0.45

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
  uiTextSize = "large",
  uiTextWeight = "thin",
  uiBoxScale = "normal",
  uiBorderColor = "gold",
  uiBorderStyle = "classic",
}
for _,spec in ipairs(GOLD_SCREEN_TOGGLE_SPECS) do
  OPTION_DEFAULTS[spec.key]=true
end

local function optionValue(key)
  if modRef and modRef.options and modRef.options.get then
    local ok, value = pcall(modRef.options.get, modRef.options, key)
    if ok and value ~= nil then return value end
  end
  return OPTION_DEFAULTS[key]
end

local function featureEnabled(key)
  return optionValue(key) ~= false
end

function GoldCompat.userTextScale()
  local v=tostring(optionValue("uiTextSize") or "normal")
  if v=="small" then return 0.90 end
  if v=="large" then return 1.12 end
  if v=="x-large" then return 1.24 end
  return 1.00
end

function GoldCompat.userTextWeight()
  local v=tostring(optionValue("uiTextWeight") or "normal")
  if v=="thin" then return 0.00 end
  if v=="bold" then return 0.90 end
  return 0.45
end

function GoldCompat.userBoxScale()
  local v=tostring(optionValue("uiBoxScale") or "normal")
  if v=="compact" then return 0.86 end
  if v=="large" then return 1.08 end
  if v=="x-large" then return 1.14 end
  return 1.00
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
  if not featureEnabled("revampedPokemonMenu") then return false end
  if not (State.activeTMParty and moveMenu and moveMenu.mon) then return false end
  if not stateExistsInStack(game, State.activeTMParty) then return false end

  local party = State.activeTMParty.party or (game.save and game.save.party) or {}
  local selected = math.max(1, math.min(State.activeTMParty.index or 1, #party))
  return party[selected] == moveMenu.mon
end

local function installVerifiedOptions(mod)
  modRef = mod

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
      key = "uiTextSize",
      type = "choice",
      label = "TEXT SIZE",
      default = "large",
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
      default = "thin",
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
  local g=love.graphics
  g.push("all")
  g.setScissor(0,0,0,0)
  local ok,result=pcall(fn,self,...)
  g.pop()
  if not ok then error(result) end
  return result
end

local function patchVanillaTextDrawing()
  -- Gold has a separate BattleState implementation. Its presentation is
  -- handled by the shared battle.overlay/render.hud compatibility path below;
  -- do not attach Gen 1 drawTextArea/drawHUDs assumptions to the facade.
  if GoldCompat.generation=="gen2" then return end

  -- These wrappers preserve lifecycle behavior and reduce redundant native
  -- drawing on classic builds. The authoritative anti-duplicate guard is the
  -- final battle.overlay scrub, which also covers WideBattle/local renderers.
  if vanillaTextPatched then return end
  vanillaTextPatched = true

  -- Chain whatever implementation exists when this mod loads.
  local originalTextArea = BattleState.drawTextArea
  if originalTextArea then
    BattleState.drawTextArea = function(self, ...)
      -- Hard override: when requested, every native battle text-area draw still
      -- runs for lifecycle/state purposes but no legacy pixels can reach frame.
      if featureEnabled("hideNativeBattleUI") then
        return runDrawInvisible(originalTextArea,self,...)
      end

      if not featureEnabled("revampedBattleUI") then
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
      if not (featureEnabled("revampedBattleUI")
          or featureEnabled("hideNativeBattleUI")) then
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

      if featureEnabled("revampedBattleUI")
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

        for i=1,6 do
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
          else
            g.setColor(0.32,0.32,0.30,0.55)
            g.setLineWidth(0.8)
            g.circle("line",cx,y0,r)
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

local function printText(text, x, y, size, color, align, width)
  local g = love.graphics
  local scaledSize=math.max(4,(tonumber(size) or 4)*UI_TEXT_SCALE*GoldCompat.userTextScale())
  local f = font(scaledSize)
  local old = g.getFont()
  g.setFont(f)

  text = tostring(text or "")
  color = color or {0.11,0.12,0.11,1}
  local shadow = {0.14,0.16,0.13,0.24}

  if width then
    g.setColor(shadow)
    g.printf(text, x+1, y+1, width, align or "left")
    g.setColor(color)
    g.printf(text, x, y, width, align or "left")
    -- Subtle second pass gives the thin pixel font a little more body without
    -- turning it into an obviously bold face.
    g.printf(text, x+GoldCompat.userTextWeight(), y, width, align or "left")
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
  local source=battle and battle.current and battle.current.text or nil

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
  local source=battle and battle.current and battle.current.text or nil
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
  return UI_BORDER_COLORS[optionValue("uiBorderColor")] or UI_BORDER_COLORS.gold
end

local function setCurrentBorderColor(alpha)
  local c = GoldCompat.currentBorderColor()
  love.graphics.setColor(c[1],c[2],c[3],alpha or 1)
end

function GoldCompat.currentBorderStyle()
  return optionValue("uiBorderStyle") or "classic"
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

  -- Keep a little breathing room inside the badge and bias the label upward.
  -- Pixel fonts visually sit lower than their nominal bounding box, so a
  -- slight negative offset looks centered against the HP bar.
  local hpPadX = h*0.18
  local hpTextY = y + math.max(0,(h-hpTextH)*0.5) - h*0.10
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
  -- EXP row in pure logical units (no fixed pixels). It stays aligned with the
  -- HP bar's left start, but sits BELOW the status badge (which occupies
  -- y+22.2*s..29.2*s at x+8*s) so PSN/PAR/SLP/FRZ/BRN text has free space
  -- under "HP". Lifted per request (total 10*s above plate bottom).
  local rowY = plateY + plateH - 10*s

  -- Rail starts at the HP bar's left (shifted 23*s right per request) and is
  -- 60% of the available width.
  local barX = plateX + 23*s
  local barW = math.max(8*s, (right - barX) * 0.60)

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

  local okMon,Mon=pcall(require,"src.battle.gen2.Mon")

  local function resolve(mon)
    if type(mon)~="table" then return nil end
    local g=mon.gender
    if g=="male" or g=="female" then return g end

    local species=mon.species or mon.id
    local dvs=mon.dvs
    local def=species and data and data.pokemon and data.pokemon[species]
    if okMon and Mon and type(Mon.gender)=="function" and def and dvs then
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
  printText(enemyName,x+7*s,y+2.0*s,6.4*s,textColor)
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
      local gy=y+5.35*s
      local iconSize=math.max(9,math.min(12,3.0*s))
      GoldCompat.drawGenderIcon(gx,gy,iconSize,gender)
    end
  end
  printText("Lv."..tostring((b.mon and b.mon.level) or "?"),
            x+64*s,y+2.2*s,5.5*s,textColor,"right",39*s)

  drawStyledHP(x+7*s,y+14.5*s,97*s,7*s,b)

  -- Numeric HP readout inside the box, right-aligned to the END of the HP bar
  -- (x+7*s + 97*s = x+104*s) so the left-under-HP zone is free for the status
  -- text (PSN/PAR/etc.) drawn at x+8*s.
  pcall(function()
    local hpText=tostring(shownHP(b)).." / "..tostring(maxHP(b))
    printText(hpText,x+51*s,y+21.8*s-2*s,4.4*s,textColor,"right",53*s)
  end)
  local status=statusText(battle,b)
  if status then
    local r,g,bb,aa=statusColor(status)
    printText(status,x+12*s,y+24.0*s,3.8*s,{r,g,bb,aa})
  end
end

local function drawPlayerHUD(battle, s, commandRect)
  if not playerVisible(battle) then return end

  local sw=love.graphics.getWidth()
  local w,h=116*s,35*s
  local margin=7*s
  local iosTop=featureEnabled("iosTopBattleHUD")
  local x=sw-w-margin
  local y=iosTop and margin or (commandRect.y-h-6*s+2*s)
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
    printText(playerName,x+8*s,y+1.8*s,6.4*s,textColor)
  end)

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
      local gy=y+5.15*s
      local iconSize=math.max(9,math.min(12,3.0*s))
      GoldCompat.drawGenderIcon(gx,gy,iconSize,gender)
    end
  end
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
      -- No background pill: draw status text directly on the plate.
      printText(status,x+14*s,y+24.0*s,3.8*s,{r,g,bb,aa})
      lg.setColor(1,1,1,1)
    end
  end)

  -- Numeric HP is also isolated.
  pcall(function()
    local hpText=tostring(shownHP(b)).." / "..tostring(maxHP(b))
    printText(hpText,x+55*s,y+21.8*s-2*s,4.4*s,textColor,"right",53*s)
  end)
end

function GoldCompat.drawBattleGenderOverlay(battle,s,commandRect)
  return false
end

-- -------------------------------------------------------------------------
-- Responsive command + dialogue panels
-- -------------------------------------------------------------------------

local function battleMenuScale()
  local sw,sh=love.graphics.getDimensions()
  local raw=math.min(sw/1280,sh/720)

  local scale
  if raw <= 1.5 then
    scale=clamp(raw,0.60,1.18)
  else
    scale=clamp(1.18 + (raw-1.5)*0.75,1.18,2.30)
  end

  -- Optional mobile presentation affects ONLY our custom battle interface.
  -- Mobile screens need the HUD to consume LESS of the viewport, not more.
  -- Desktop/non-mobile behavior is byte-for-byte equivalent when this is off.
  if featureEnabled("mobileBattleUI") then
    local portrait = sh > sw
    scale=scale*(portrait and 0.72 or 0.82)
  end
  return scale*GoldCompat.userBoxScale()
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

function GoldCompat.moveGeometry()
  local sw, sh = love.graphics.getDimensions()
  local u = battleMenuScale()

  local mobile=featureEnabled("mobileBattleUI")
  local portrait=sh>sw
  local w = clamp((mobile and (portrait and 570 or 630) or 756)*u,
    mobile and 300 or 400, mobile and 1080 or 1660)
  local h = clamp((mobile and (portrait and 235 or 255) or 300)*u,
    mobile and 160 or 215, mobile and 455 or 690)
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

local function drawMoveSelect(battle)
  if not (battle and battle.phase == "moveSelect"
      and battle.player and battle.player.curMoves) then
    return
  end

  local rect = GoldCompat.moveGeometry()
  drawPanelBase(rect)

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
  local visible=6
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

  local visible=6
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

  showMessages({booted,Strings("It contained\n%s!",moveName)},function()
    Screens.push(game,"PartyMenu",{
      pickOnly=true,
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
    visibleRows=6,
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

    if self.__gen3uiBagAction and featureEnabled("revampedOverworldMenus") then
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
    if featureEnabled("revampedOverworldMenus") then
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
        if not featureEnabled("revampedOverworldMenus") then
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

    if not featureEnabled("revampedOverworldMenus") then
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
    if featureEnabled("revampedPokemonMenu") then
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
    if featureEnabled("revampedPokemonMenu")
        and self.game and self.mon and self.game.input then
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
    if featureEnabled("revampedBattleUI")
        and featureEnabled("revampedPokemonMenu")
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
    if not featureEnabled("revampedPokemonMenu") then
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
      if not (featureEnabled("revampedBattleUI") and battle and self.mon) then
        if State.activeBattleStatBox==self then State.activeBattleStatBox=nil end
        return originalStatDraw(self)
      end

      State.activeBattleStatBox=self
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
      mod.log("info", "Gen 3 Inspired UI Overhaul: overworld START/Bag/Party UI alpha active")
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


local function findBagStateInStack(game)
  return bagStateForMenu(game)
end

local function finalCanvas()
  local sw, sh = love.graphics.getDimensions()
  local raw = math.min(sw / 160, sh / 144)
  local scale = math.floor(raw)
  if scale < 1 then scale = raw end

  -- UI BOX SIZE is intentionally allowed to exceed the full 160x144
  -- fit-scale slightly. Most hanging panels have generous logical margins,
  -- so this makes LARGE / X-LARGE visibly meaningful without changing their
  -- internal layout. COMPACT still shrinks normally.
  local boxScale=GoldCompat.userBoxScale()
  if boxScale>1 then
    scale=math.min(scale*boxScale,raw*1.14)
  else
    scale=scale*boxScale
  end

  local ox = math.floor((sw - 160*scale) * 0.5 + 0.5)
  local oy = math.floor((sh - 144*scale) * 0.5 + 0.5)
  return ox, oy, scale
end

-- Full-screen interfaces must honor the real display bounds at every UI box
-- size. Hanging/overworld panels continue to use finalCanvas(), which retains
-- its intentional slight Large/X-Large overscan.
local function safeFullCanvas(marginPx)
  local sw,sh=love.graphics.getDimensions()
  local margin=marginPx or 4
  local raw=math.min((sw-margin*2)/160,(sh-margin*2)/144)
  local base=math.floor(math.min(sw/160,sh/144))
  if base<1 then base=math.min(sw/160,sh/144) end
  local requested=base*GoldCompat.userBoxScale()
  local scale=math.min(requested,raw)
  if scale<=0 then scale=raw end
  local ox=math.floor((sw-160*scale)*0.5+0.5)
  local oy=math.floor((sh-144*scale)*0.5+0.5)
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
  local g=love.graphics
  local ox,oy,sc=finalCanvas()
  local items=state.items or {}
  local count=#items
  if count<1 then return end

  -- The first Mart choice is an overworld popup, matching START / UI OPTIONS.
  -- Native BUY/SELL/QUIT actions remain untouched; only presentation changes.
  local rowH=12
  local w=64
  local h=count*rowH+20
  local x=92
  local y=math.max(5,math.floor((144-h)/2))

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

  g.setColor(0.10,0.10,0.09,1)
  g.rectangle("fill",x+4,y+4,w-8,11)

  for i,item in ipairs(items) do
    local yy=y+17+(i-1)*rowH
    if i==(state.index or 1) then
      g.setColor(0.10,0.10,0.09,1)
      g.rectangle("fill",x+4,yy,w-8,rowH-1)
    end
  end
  g.pop()

  finalText("POKé MART",x+8,y+5,4.15,{1,1,1,1},ox,oy,sc)

  for i,item in ipairs(items) do
    local yy=y+17+(i-1)*rowH
    local selected=i==(state.index or 1)
    local label=tostring(item.label or "")
    if label:upper()=="QUIT" then label="EXIT" end
    finalText(label,x+9,yy+1,4.5,
      selected and {1,1,1,1} or {0.05,0.05,0.05,1},
      ox,oy,sc)
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

local function drawShopListFinal(game,state)
  local title=tostring(state.title or "SHOP"):upper()
  local ox,oy,sc=GoldCompat.drawShopFrame(game,title=="SELL" and "POKé MART — SELL" or "POKé MART — BUY")
  local g=love.graphics

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
      if item.right then
        local rw=finalTextWidth(tostring(item.right),3.9,sc)
        finalText(tostring(item.right),145-rw,y,3.9,
          idx==selected and {0.98,0.97,0.92,1} or {0.12,0.12,0.11,1},
          ox,oy,sc)
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

function GoldCompat.drawShopQuantityFinal(game,shop,qty)
  if shop.__gen3uiShopSell then
    drawShopSellBagFinal(game,shop)
  else
    drawShopListFinal(game,shop)
  end
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
    local rowH=11
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

  local rowH = 12
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

  local rowH = 12
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

local function drawShopSellBagFinal(game,state)
  -- SELL is inventory browsing, so present the live Shop ListMenu through the
  -- same Gen 3 Bag layout used elsewhere in this mod. Do NOT construct a fake
  -- BagMenu: BagMenu.new has runtime/state side effects and native renderers may
  -- draw into the 160x144 canvas directly.
  if state.scroll==nil then state.scroll=0 end
  if state.rows==nil then state.rows=7 end
  drawBagFinal(game,state)

  -- Small Mart context overlay; transaction logic remains native.
  local ox,oy,sc=finalCanvas()
  local money=("¥%d"):format(shopMoney(game))
  local mw=finalTextWidth(money,4.1,sc)
  finalText("SELL",9,6,4.1,{0.26,0.24,0.19,1},ox,oy,sc)
  finalText(money,150-mw,6,4.1,{0.12,0.12,0.11,1},ox,oy,sc)
  return true
end


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

local function drawSelectedBattleSprite(game, mon, x, y, w, h, kind)
  local resolver = spritePortraitResolver
  if not (resolver and resolver.resolve) then return false end

  local ok, img, meta = pcall(resolver.resolve, game, mon, kind)
  if not (ok and img) then return false end

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
  love.graphics.draw(img, dx, dy, 0, scale, scale)

  if type(meta)=="table" and meta.trueColor then
    local okPalette,PaletteFX=pcall(require,"src.render.PaletteFX")
    if okPalette and PaletteFX and type(PaletteFX.markTrueColor)=="function" then
      pcall(PaletteFX.markTrueColor,dx,dy,iw*scale,ih*scale)
    end
  end

  love.graphics.setColor(1,1,1,1)
  return true
end

local function partyLogicalCanvas()
  local sw, sh = love.graphics.getDimensions()
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
  return ox, oy, scale
end

local function partySlotPanel(x,y,w,h,selected)
  local g = love.graphics
  -- Borderless card: drop the dark outer fill so the panel is transparent
  -- except for its cream face (keeps overlays such as the DV reader visible).
  g.setColor(selected and {0.975,0.955,0.88,1} or {0.99,0.985,0.955,1})
  roundedRect("fill",x,y,w,h,3)
  if selected then
    g.setColor(0.72,0.58,0.28,1)
    roundedRect("line",x+3,y+3,w-6,h-6,2)
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

  -- Repaint the ENTIRE information region every frame. This is intentionally
  -- opaque so no text from the normal details panel or native MoveLearnMenu
  -- can remain visible underneath the integrated replacement interface.
  local areaX = x + 6
  local areaY = y + 63
  local areaW = w - 12
  local areaH = h - 67

  g.setColor(0.99,0.975,0.90,1)
  g.rectangle("fill",areaX,areaY,areaW,areaH)

  g.setColor(0.70,0.68,0.59,1)
  g.rectangle("fill",x+7,y+64,w-14,1)

  partyText("REPLACE MOVE",x+8,y+65,3,{0.16,0.16,0.14,1})

  -- Incoming move occupies a fixed header row.
  partyText("NEW",x+8,y+70,2,{0.46,0.34,0.10,1})
  local incoming = newName
  if #incoming > 12 then incoming = incoming:sub(1,11).."." end
  partyText(incoming,x+20,y+69,3,{0.06,0.06,0.06,1})

  -- Four fixed rows, with enough vertical separation that no fifth/cancel
  -- state can collide with move text.
  local moveTop = y + 76
  local rowH = 6
  local rowX = x + 7
  local rowW = w - 14
  local ppRight = x + w - 7
  local selected = math.max(1,math.min(learn.index or 1,#moves+1))

  for i=1,4 do
    local mv = moves[i]
    local my = moveTop + (i-1)*rowH
    local isSelected = (i == selected)

    if isSelected then
      g.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",rowX,my-1,rowW,6,1)
    end

    if mv then
      local name = partyMoveName(game,mv)
      if #name > 12 then name = name:sub(1,11).."." end
      local col = isSelected and {1,1,1,1} or {0.06,0.06,0.06,1}
      partyText(name,x+10,my,2,col)

      local pp = partyMovePP(game,mv)
      if pp ~= "" then
        local pw = partyTextWidth(pp,2)
        partyText(pp,ppRight-pw,my,2,
          isSelected and {1,1,1,1} or {0.20,0.20,0.18,1})
      end
    else
      partyText("---",x+10,my,2,
        isSelected and {1,1,1,1} or {0.38,0.38,0.34,1})
    end
  end

  -- No CANCEL label is ever drawn in this panel. The native fifth cursor
  -- position still exists logically and is represented only by the bottom prompt.
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

  partyText("MOVES", x+8, detailDividerY+2, 3, {0.16,0.16,0.14,1})

  -- Compact four-row move block.
  local moveTop = detailDividerY + 7
  local moveRowH = 4
  local ppRight = x + w - 7

  for i=1,4 do
    local m = moves[i]
    local my = moveTop + (i-1)*moveRowH
    local name = partyMoveName(game,m)
    local pp = partyMovePP(game,m)

    if #name > 12 then
      name = name:sub(1,11).."."
    end

    partyText(name, x+8, my, 3, {0.06,0.06,0.06,1})

    if pp ~= "" then
      local pw = partyTextWidth(pp, 2)
      partyText(pp, ppRight-pw, my, 2, {0.20,0.20,0.18,1})
    end
  end

  -- Stats stay in a fixed footer, isolated from moves.
  local statsDividerY = y + h - 13
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
    local title=tostring(state.title or ""):upper()
    local source=nil
    if title=="PARTY (DEPOSIT)" then
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
  local rowH=13
  for i,item in ipairs(items) do
    local y=ry+5+(i-1)*rowH
    local selected=i==(state.index or 1)
    if selected then
      g.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",rx+4,y-1,rw-8,10,2)
      g.setColor(0.62,0.48,0.20,1)
      roundedRect("line",rx+5,y,rw-10,8,2)
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
  local up=tostring(state.title or ""):upper()
  local footer="Choose a POKéMON."
  if up:find("WITHDRAW",1,true) then
    footer="Withdraw which POKéMON?"
  elseif up:find("DEPOSIT",1,true) then
    footer="Deposit which POKéMON?"
  elseif up:find("RELEASE",1,true) then
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
      partyText(st,lx+12,ly+54,4,
        st=="FNT" and {0.52,0.10,0.08,1} or {0.40,0.15,0.44,1})
    end

    -- Live Party EXP, matching the battle HUD's blue language.
    partyText("EXP",lx+9,ly+58,3,{0.34,0.45,0.50,1})
    GoldCompat.drawPartyExpBar(game,mon,lx+19,ly+59,lw-29)

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

    PartyMenu.drawIcon(game,m,rx+2,y,false,state.blink or 0)

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
    local sw=62
    local sh=math.min(66,6+count*12)
    local sx=160-sw-5
    local sy=math.max(5,124-sh)
    GoldCompat.frlgMenuPanel(sx,sy,sw,sh)

    for si,entry in ipairs(state.subItems) do
      local yy=sy+4+(si-1)*12
      if si==state.subIndex then
        GoldCompat.frlgSelection(sx+3,yy,sw-6,11)
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


function GoldCompat.isGen1SavePromptBox(box)
  if GoldCompat.generation~="gen1" or not box or not box.choice then return false end
  local parts={}
  for _,page in ipairs(box.pages or {}) do
    for _,line in ipairs(page or {}) do parts[#parts+1]=tostring(line) end
  end
  local all=table.concat(parts," "):upper()
  return all:find("BADGES",1,true)
      and all:find("POK",1,true)
      and all:find("SAVE",1,true)
      and all:find("TIME",1,true)
end

function GoldCompat.drawGen1SavePrompt(box)
  local game=box and box.game
  local save=game and game.save
  if not save then return false end
  local g=love.graphics
  local sw,sh=g.getDimensions()
  local sc=math.max(1,sh/144)
  local x=math.floor(sw-81*sc)
  local y=math.floor(18*sc)
  local w=math.floor(76*sc)
  local h=math.floor(103*sc)

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
  g.setColor(0.84,0.82,0.73,1)
  g.rectangle("fill",x+7*sc,y+64*sc,w-14*sc,1*sc)
  g.pop()

  local badges=0
  pcall(function() badges=require("src.inventory.Badges").count(game.data,save) end)
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

  g.push("all")
  g.origin()
  g.setColor(0.08,0.08,0.07,1)
  roundedRect("fill",x+6*sc,y+71*sc,w-12*sc,24*sc,2*sc)
  g.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",x+8*sc,y+73*sc,w-16*sc,20*sc,1.5*sc)
  g.pop()
  printText("Save the game?",x+12*sc,y+79*sc,2.8*sc,dark,
    "left",math.floor(w-24*sc))
  return true
end

function GoldCompat.drawDialogueThemeFinal(box)
  if featureEnabled("revampedSaveUI") and GoldCompat.isGen1SavePromptBox(box) then
    return GoldCompat.drawGen1SavePrompt(box)
  end
  local g = love.graphics
  local sw,sh = g.getDimensions()
  local sc = math.max(1,sh/144)
  local margin = math.floor(4*sc+0.5)
  -- Native TextBox dialogue follows the same adaptive sizing contract as
  -- battle dialogue. Large text gains height instead of crossing the scissor.
  local _,heightScale=GoldCompat.dialogueLayoutScale()
  local logicalH=math.max(24,math.min(42,24*heightScale))
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
  local texts = {}

  for i=1,visible do
    texts[i] = GoldCompat.dialogueVisibleText(box,i)
  end

  local textGrowth=math.max(0,GoldCompat.userTextScale()-1)
  local innerTop=math.max(3,math.floor((3+textGrowth*2)*sc+0.5))
  local innerBottom=math.max(4,math.floor((4+textGrowth*2)*sc+0.5))
  local innerH=math.max(1,h-innerTop-innerBottom)

  local pxSize,glyphH,lineH,blockH=fittedDialogueMetrics(
    texts,preferred,minimum,contentW,innerH)

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

  if (box.waiting or (box.done and not box.choice and not box.auto and not box.stay))
      and (box.blink or 0) < 30 then
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

    finalText("A / B: MOVES",9,134,2.6,{0.96,0.95,0.90,1},ox,oy,sc)
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

    finalText("A / B: BACK",9,134,2.6,{0.96,0.95,0.90,1},ox,oy,sc)
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
  local okNests,Nests=pcall(require,"src.core.gen2.Nests")

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
    if okNests and Nests and type(Nests.landmark)=="function" and map.landmark then
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

  g.setColor(0.94,0.93,0.87,1)
  g.rectangle("fill",0,0,160,144)

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

  local visibleRows=8
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
    local y=31+(row-1)*11

    if n==selected then
      g.push("all")
      g.translate(ox,oy)
      g.scale(sc,sc)
      g.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",99,y-2,53,10,2)
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

  g.setColor(0.94,0.93,0.87,1)
  g.rectangle("fill",0,0,160,144)

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
  local rowH=9
  local h=6+count*rowH
  local x=119

  local y=31
  if DexUI.active and DexUI.active.items then
    local total=#DexUI.active.items
    local selected=math.max(1,math.min(DexUI.active.index or 1,math.max(1,total)))
    local visibleRows=8
    local first=math.max(1,selected-math.floor(visibleRows/2))
    if total>visibleRows then
      first=math.min(first,total-visibleRows+1)
    end

    local visibleRow=selected-first+1
    local selectedY=31+(visibleRow-1)*11
    local belowY=selectedY+10

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
      roundedRect("fill",x+3,yy-1,w-6,8,2)
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
        modRef.log("error","Gen 3 UI Pokédex DATA renderer failed: "
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
        modRef.log("error","Gen 3 UI Pokédex action overlay failed: "
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
      modRef.log("error","Gen 3 UI Pokédex renderer failed; native fallback: "
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
    if not featureEnabled("revampedDialogueBoxes") then
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
    if not featureEnabled("revampedDialogueBoxes") then
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

    if list and (upperTitle=="POKéDEX" or upperTitle=="POKEDEX") then
      list.__gen3uiPokedex=true
      DexUI.active=list
    elseif list and opts and opts.dialogue
        and (upperTitle=="BUY" or upperTitle=="SELL") then
      list.__gen3uiShopList=true
      list.__gen3uiShopSell=(upperTitle=="SELL")
    elseif list and GoldCompat.pcListTitle(title) then
      list.__gen3uiPCList=true
    end
    return list
  end
end


local function handleModOptionChanged(mod,payload)
  if not payload or payload.mod ~= mod.id then return end

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
  local Pokegear=require("src.ui.gen2.Pokegear")
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
    Pokegear.__gen3uiOriginalDrawPanel(self)
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

  G.push("all")
  G.translate(ox,oy)
  G.scale(sc,sc)

  -- Exact Gen 1 Party screen foundation.
  G.setColor(0.94,0.93,0.87,1)
  G.rectangle("fill",0,0,160,144)

  G.setColor(0.08,0.08,0.08,1)
  G.rectangle("fill",4,4,152,16)
  G.setColor(0.99,0.985,0.955,1)
  G.rectangle("fill",5,5,150,14)
  G.pop()

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

    if isSelected then
      G.setColor(0.10,0.10,0.10,1)
      roundedRect("fill",rx,yy,rw,slotH,3)
      G.setColor(0.985,0.975,0.92,1)
      roundedRect("fill",rx+2,yy+2,rw-4,slotH-4,2)
      G.setColor(0.62,0.48,0.20,1)
      roundedRect("line",rx+3,yy+3,rw-6,slotH-6,2)
    else
      partySlotPanel(rx,yy,rw,slotH,false)
    end

    G.push("all")
    G.translate(rx+2,yy)
    self:drawIcon(m,0,0)
    G.pop()
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
      local ok,Nests=pcall(require,"src.core.gen2.Nests")
      if ok and Nests then
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
  G.setColor(0.94,0.93,0.87,1)
  G.rectangle("fill",0,0,160,144)

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
  local PokedexMenu=require("src.ui.gen2.PokedexMenu")
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
  PokedexMenu.__gen3uiOriginalDrawPanel(self)
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
  return summary and summary.moves and summary.moves[id] or nil
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

  local ok,Mon=pcall(require,"src.battle.gen2.Mon")
  if not ok or not Mon then return 0 end
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

function GoldCompat.drawGoldMoveManager(summary)
  local mon=summary.mon
  if not mon then return end

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

  G.setColor(0.12,0.12,0.11,1)
  roundedRect("fill",7,27,72,101,3)
  roundedRect("fill",82,27,71,101,3)
  G.setColor(0.99,0.985,0.95,1)
  roundedRect("fill",9,29,68,97,2)
  roundedRect("fill",84,29,67,97,2)
  G.setColor(0.08,0.08,0.07,1)
  G.rectangle("fill",4,132,152,8)
  G.pop()

  finalText("MOVE MANAGER",9,8,4.8,{0.06,0.06,0.06,1},ox,oy,sc)

  local moves=mon.moves or {}
  for i=1,4 do
    local mv=moves[i]
    local md=GoldCompat.summaryMoveDef(summary,mv)
    local y=35+(i-1)*20
    local selected=i==(summary.moveIndex or 1)
    local held=i==summary.swapFrom

    G.push("all")
    G.translate(ox,oy)
    G.scale(sc,sc)
    if selected then
      G.setColor(0.11,0.28,0.38,1)
      roundedRect("fill",12,y-1,61,17,2)
    elseif held then
      G.setColor(0.74,0.59,0.20,1)
      roundedRect("fill",12,y-1,61,17,2)
    end
    G.pop()

    finalText(GoldCompat.summaryMoveName(summary,mv),
      16,y+2,3.15,
      selected and {0.98,0.97,0.92,1} or {0.08,0.08,0.08,1},
      ox,oy,sc,"left",38)

    if mv then
      local pp=type(mv)=="table" and (mv.pp or "?") or "?"
      local maxpp=type(mv)=="table" and (mv.maxPp or mv.maxPP)
      maxpp=maxpp or (md and md.pp) or pp
      finalText(("PP %s/%s"):format(pp,maxpp),53,y+8,2.2,
        selected and {0.90,0.91,0.87,1} or {0.32,0.32,0.29,1},
        ox,oy,sc,"right",18)
    end
  end

  local current=moves[summary.moveIndex or 1]
  local def=GoldCompat.summaryMoveDef(summary,current)
  finalText("MOVE DATA",88,35,2.7,{0.40,0.40,0.37,1},ox,oy,sc)

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

  finalText(summary.swapFrom and "A: PLACE   B: CANCEL"
      or "A: PICK UP   B: BACK",
    9,134,2.35,{0.96,0.95,0.90,1},ox,oy,sc)
end

function GoldCompat.drawGoldSummary(summary,winW,winH)
  if not (summary and summary.mon) then return end

  -- Eggs keep their purpose-built native Gold summary screen; revealing the
  -- hidden species/stats would violate Gold's own egg flow.
  if summary.mon.isEgg then
    local Summary=require("src.ui.gen2.SummaryMenu")
    if Summary.__gen3uiOriginalDrawWidescreen then
      return Summary.__gen3uiOriginalDrawWidescreen(summary,winW,winH)
    end
  end

  if summary.moveDetail or summary.moveScreen then
    return GoldCompat.drawGoldMoveManager(summary)
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
  local first=(pack.scroll or 0)+1
  local visible=tonumber(pack.visibleRows)
      or (embedded and 6 or 7)
  for r=1,visible do
    local idx=first+r-1
    local yy=y+23+(r-1)*10
    local row=rows[idx]
    local isCancel=(idx>#rows and idx==(pack.index or 1))
    local selected=idx==(pack.index or 1)

    if selected then
      G.setColor(0.10,0.10,0.09,1)
      roundedRect("fill",x+6,yy-1,w-12,9,1.5)
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

  -- Scroll indicators reflect the same authoritative viewport as the list.
  if (pack.scroll or 0)>0 then
    GoldCompat.panelText("▲",x+w-11,y+20,2.1,{0.30,0.30,0.27,1})
  end
  if ((pack.scroll or 0)+visible)<#rows then
    GoldCompat.panelText("▼",x+w-11,y+h-34,2.1,{0.30,0.30,0.27,1})
  end

  for r=1,visible do
    local idx=first+r-1
    local yy=y+23+(r-1)*10
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
        GoldCompat.panelText(entry.name or entry.id,18,yy,3.9,
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
    local okSpecials,Specials=pcall(require,"src.script.gen2.Specials")
    if okSpecials and Specials and type(Specials.dexCounts)=="function" then
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
  if pc.phase=="deposit" and pc.pack then
    -- Item-PC deposit is literally a chooser PACK in Gold; use the same themed
    -- hanging bag presentation, but on the PC's cream background.
    local ox,oy,sc=finalCanvas()
    local G=love.graphics
    G.push("all"); G.translate(ox,oy); G.scale(sc,sc)
    G.setColor(0.94,0.93,0.87,1); G.rectangle("fill",0,0,160,144)
    G.pop()
    return GoldCompat.drawGoldPack(pc.pack,winW,winH,true)
  end

  local facade={
    game=pc.game, save=pc.save, entries=pc.entries, index=pc.index,
    picking=false, message=pc.message
  }
  GoldCompat.drawGoldPcRoot(facade)

  if pc.phase=="withdraw" or pc.phase=="toss" then
    local rows=pc.rows or {}
    local first=(pc.scroll or 0)+1
    for r=1,6 do
      local idx=first+r-1
      local row=rows[idx]
      if row then
        GoldCompat.panelText(row.name,87,31+(r-1)*12,2.7,
          idx==(pc.listIndex or 1) and {0.70,0.46,0.16,1}
            or {0.06,0.06,0.06,1},"left",43)
        GoldCompat.panelText("×"..tostring(row.count or 1),132,31+(r-1)*12,2.5,
          {0.24,0.24,0.22,1},"right",16)
      end
    end
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
    PackMenu.draw=function(self) self.__gen3uiGoldOverlayKind="pack" end
    PackMenu.drawWidescreen=function(self,winW,winH)
      self.__gen3uiGoldOverlayKind="pack"
      return
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
    MartMenu.draw=function(self) self.__gen3uiGoldOverlayKind="mart" end
    MartMenu.drawWidescreen=function(self,winW,winH)
      self.__gen3uiGoldOverlayKind="mart"
      return
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
    CenterPcMenu.draw=function(self) self.__gen3uiGoldOverlayKind="centerpc" end
    CenterPcMenu.drawWidescreen=function(self,winW,winH)
      self.__gen3uiGoldOverlayKind="centerpc"
      return
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

  local okItem,ItemPcMenu=pcall(require,"src.ui.gen2.ItemPcMenu")
  if okItem and type(ItemPcMenu)=="table" and not ItemPcMenu.__gen3uiVisualPatched then
    ItemPcMenu.__gen3uiVisualPatched=true
    ItemPcMenu.__gen3uiOriginalDrawWidescreen=ItemPcMenu.drawWidescreen
    ItemPcMenu.drawWidescreen=function(self,winW,winH)
      return GoldCompat.drawGoldItemPc(self,winW,winH)
    end
  end

  GoldCompat.serviceUiInstalled=true
end


function GoldCompat.countTruthy(t)
  local n=0
  for _,v in pairs(t or {}) do if v then n=n+1 end end
  return n
end

function GoldCompat.drawGoldSave(saveMenu)
  local ox,oy,sc=finalCanvas()
  local G=love.graphics
  local Save2=require("src.core.gen2.Save")
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
  local Trainer=require("src.ui.gen2.TrainerCard")
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

  local rowH=12
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
  local rows=menu.rows or {}
  local total=#rows+1
  local index=math.max(1,math.min(total,menu.index or 1))
  local visible=math.min(7,total)
  local first=math.max(1,math.min(index-2,math.max(1,total-visible+1)))

  local rowH=12
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

  local rowH=11
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
      pcall(function()
        require("src.render.PaletteFX").markTrueColor(dx,dy,dw,targetH)
      end)
    end
    g.pop()
  end

  local player=save.player or {}
  local caught=0
  for _ in pairs(save.pokedex and save.pokedex.owned or {}) do caught=caught+1 end
  local t=math.floor(save.playTime or 0)
  local badgeCount=0
  pcall(function()
    badgeCount=require("src.inventory.Badges").count(game.data,save)
  end)

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

  local okBadges,Badges=pcall(require,"src.inventory.Badges")
  local defs=okBadges and game and Badges.list(game.data) or {}
  if card.badges and card.faces and okBadges then
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
  if not featureEnabled("revampedLevelUpUI") then return false end
  local mon=box and box.mon
  local game=box and box.game
  if not (mon and game and mon.stats) then return false end

  local level=tonumber(mon.level) or 1
  local def=game.data and game.data.pokemon and game.data.pokemon[mon.species]
  local old={}
  local okStats,Stats=pcall(require,"src.pokemon.Stats")
  if okStats and Stats and type(Stats.calc)=="function" and def then
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
    if type(OptionsMenu.__gen3uiOriginalUpdate)=="function" then
      OptionsMenu.update=function(self,...)
        if goldScreenEnabled("revampedOptionsUI") then
          self.isOpaque=false
          self.__gen3uiHangingOptions=true
        end
        return callOriginal(OptionsMenu.__gen3uiOriginalUpdate,self,...)
      end
    end

    OptionsMenu.draw=function(self,...)
      if screenFeatureEnabled("revampedOptionsUI") then
        self.__gen3uiHangingOptions=true
        self.isOpaque=false
        State.activeGen1Options=self
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
    ManagerState.draw=function(self,...)
      if screenFeatureEnabled("revampedModsUI") then
        self.__gen3uiHangingMods=true
        self.isOpaque=false
        State.activeGen1Mods=self
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
    if type(TrainerCard.__gen3uiOriginalUpdate)=="function" then
      TrainerCard.update=function(self,...)
        if goldScreenEnabled("revampedTrainerCardUI") then
          self.isOpaque=false
          self.__gen3uiHangingTrainer=true
        end
        return callOriginal(TrainerCard.__gen3uiOriginalUpdate,self,...)
      end
    end

    TrainerCard.draw=function(self,...)
      if screenFeatureEnabled("revampedTrainerCardUI") then
        self.__gen3uiHangingTrainer=true
        self.isOpaque=false
        State.activeGen1TrainerCard=self
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
      if screenFeatureEnabled("revampedLevelUpUI") then
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

  GoldCompat.gen1ModernScreensInstalled=true
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
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(SaveMenu.__gen3uiOriginalDraw,self,...)
    end
    SaveMenu.drawWidescreen=function(self,...)
      if goldScreenEnabled("revampedSaveUI") then
        self.__gen3uiGoldOverlayKind="save"
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
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(OptionsMenu.__gen3uiOriginalDraw,self,...)
    end

    OptionsMenu.drawWidescreen=function(self,...)
      if goldScreenEnabled("revampedOptionsUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="options"
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
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(TrainerCard.__gen3uiOriginalDraw,self,...)
    end

    TrainerCard.drawWidescreen=function(self,...)
      if goldScreenEnabled("revampedTrainerCardUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="trainer"
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
        return
      end
      self.__gen3uiGoldOverlayKind=nil
      return callOriginal(ManagerState.__gen3uiOriginalDraw,self,...)
    end

    ManagerState.drawWidescreen=function(self,...)
      if goldScreenEnabled("revampedModsUI") then
        self.isOpaque=false
        self.__gen3uiGoldOverlayKind="mods"
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
    PartyMenu.drawWidescreen=function(self,winW,winH)
      return GoldCompat.drawGoldPartyMenu(self,winW,winH)
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
      if goldScreenEnabled("revampedPokemonMenu")
          and input
          and self.mon
          and not self.mon.isEgg
          and not self.moveDetail
          and input:wasPressed("select") then
        -- Native Gold only accepts SELECT on GREEN_PAGE. Temporarily expose
        -- that page to the original update for this frame so the engine itself
        -- enters MoveScreenLoop, then restore the user's visible tab.
        local visiblePage=self.page
        self.page=SummaryMenu.GREEN_PAGE or 2
        local result=SummaryMenu.__gen3uiOriginalUpdate(self,dt)
        self.page=visiblePage
        return result
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
      return GoldCompat.drawGoldPokedex(self,winW,winH)
    end

    -- Belt-and-suspenders instance override: Screens may have resolved the
    -- Gen2PokedexMenu factory before this patch, but new instances still pass
    -- through this constructor and receive our widescreen renderer directly.
    PokedexMenu.new=function(...)
      local self=PokedexMenu.__gen3uiOriginalNew(...)
      self.drawWidescreen=function(inst,winW,winH)
        return GoldCompat.drawGoldPokedex(inst,winW,winH)
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

  local okMon,Mon=pcall(require,"src.battle.gen2.Mon")
  local def=state.pokemon and mon.species and state.pokemon[mon.species]
  local newStats=mon.stats or {}
  local oldStats={}
  if okMon and Mon and def and type(Mon.stats)=="function" then
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
  if not featureEnabled("revampedLevelUpUI") then
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
  local okPal,Palettes=pcall(require,"src.world.gen2.Palettes")
  local okGbc,GbcPalette=pcall(require,"src.render.GbcPalette")
  local colors=okPal and state.palettes and
    Palettes.trainerColors(state.palettes,state.enemyTrainerClass) or nil

  local function body()
    G.draw(img,px,py,0,scale,scale)
  end
  if colors and okGbc and GbcPalette and GbcPalette.available
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

  GoldBattleState.advanceQueue=function(self,...)
    -- The next native queue item is still visible here, before the engine
    -- removes it. Capture LEVEL at the same moment the "grew to level" line
    -- becomes current.
    local event=self.queue and self.queue[1]
    if self.__gen3uiLevelPopup and (not event or event.kind~="level") then
      self.__gen3uiLevelPopup=nil
    end
    if event and event.kind=="level" and featureEnabled("revampedLevelUpUI") then
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
    local suppressChoice=featureEnabled("revampedBattleUI")
      and (self.phase=="ask-shift" or self.phase=="ask-nickname"
        or self.phase=="ask-forget" or self.phase=="stop-learning")
      and (self.messageTimer or 0)<=0
    local timer=self.messageTimer
    if suppressChoice then self.messageTimer=1 end
    local result=original(self,...)
    if suppressChoice then self.messageTimer=timer end
    if featureEnabled("revampedBattleUI")
        or featureEnabled("hideNativeBattleUI") then
      -- Erase only Gold's native HUD/text/menu tile regions after it has drawn.
      -- Pokémon/trainer pictures occupy the complementary parts of the 160x144
      -- battle canvas and remain fully engine-owned.
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
        mod.log("error","Gen 3 UI Mart main failed; falling back native: "..tostring(err))
      end
      return false
    end
    return true
  end

  if shopTop.__gen3uiShopList then
    State.activeShopList=shopTop
    State.activeShopMenu=nil
    State.activeShopQuantity=nil

    local renderer=shopTop.__gen3uiShopSell
        and drawShopSellBagFinal or drawShopListFinal
    local ok,err=pcall(renderer,game,shopTop)
    if not ok then
      shopTop.__gen3uiMartRenderFailed=true
      if mod.log then
        mod.log("error","Gen 3 UI Mart list failed; falling back native: "
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
        mod.log("error","Gen 3 UI Mart quantity failed: "..tostring(err))
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
    if shopUnder.__gen3uiShopSell then
      pcall(drawShopSellBagFinal,game,shopUnder)
    else
      pcall(drawShopListFinal,game,shopUnder)
    end
  elseif shopUnder.__gen3uiShopMain then
    pcall(drawShopMainFinal,game,shopUnder)
  end
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
    State.activeBattleStatBox=nil
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

    -- Gold START and our Pack/Mart/Center-PC service overlays are
    -- presentation-suppressed and rendered later in render.hud over the live
    -- overworld. Do not consume those screens in the native Gold guard.
    local goldTop=topState(game)
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
    if not featureEnabled("revampedBattleUI") then
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

    -- Gender is purely decorative and isolated from the core HP/name/EXP pass.
    -- A gender-render failure can no longer suppress either battle HUD.
    if okStatus and shouldDrawStatusHUD(game,visualBattle) then
      pcall(GoldCompat.drawBattleGenderOverlay,visualBattle,s,cmd)
    end
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
        mod.log("error","Gen 3 UI Gold battle HUD failed: "..tostring(errStatus))
      end
      if not okUI then
        mod.log("error","Gen 3 UI Gold battle panels failed: "..tostring(errUI))
      end
    end
    return true
  end

  if GoldCompat.renderMartForeground(mod,game) then return true end

  local pushedBattle=battleStateInStack(game)
  local topForBattle=topState(game)

  if State.activeBattleMoveLearn
      and topForBattle==State.activeBattleMoveLearn
      and pushedBattle
      and featureEnabled("revampedBattleUI")
      and featureEnabled("revampedPokemonMenu") then
    State.activeBattle=pushedBattle

    if not State.activeBattleMoveParty then
      State.activeBattleMoveParty=makeBattleMovePartyState(game,State.activeBattleMoveLearn)
    end

    if State.activeBattleMoveParty then
      local okParty,errParty=pcall(drawPartyFinal,game,State.activeBattleMoveParty)
      if not okParty then
        State.activeBattleMoveParty=nil
        if mod.log then
          mod.log("error","Gen 3 UI battle MoveLearn Party failed; native fallback: "
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
        mod.log("error","Gen 3 UI PC access renderer failed: "..tostring(err))
      end
      return true
    elseif pcTop.__gen3uiPCMain then
      State.activePCMenu=pcTop
      State.activePCAccessMenu=nil
      State.activePCList=nil
      State.activePCActionMenu=nil
      local ok,err=pcall(drawPCMainFinal,game,pcTop)
      if (not ok) and mod.log then
        mod.log("error","Gen 3 UI PC main renderer failed: "..tostring(err))
      end
      return true
    elseif pcTop.__gen3uiPCList then
      State.activePCList=pcTop
      State.activePCAccessMenu=nil
      State.activePCMenu=nil
      State.activePCActionMenu=nil
      local ok,err=pcall(drawPCListFinal,game,pcTop)
      if (not ok) and mod.log then
        mod.log("error","Gen 3 UI PC list renderer failed: "..tostring(err))
      end
      return true
    elseif pcTop.__gen3uiPCAction then
      State.activePCActionMenu=pcTop
      local ok,err=pcall(drawPCActionFinal,game,pcTop)
      if (not ok) and mod.log then
        mod.log("error","Gen 3 UI PC action renderer failed: "..tostring(err))
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
      and featureEnabled("revampedPokemonMenu") then
    State.activeItemTargetParty=itemPartyTop
    State.activeParty=itemPartyTop
    State.activeBagActionMenu=nil
    State.activeBagMenu=nil

    local okItemParty,errItemParty=pcall(drawPartyFinal,game,itemPartyTop)
    if not okItemParty then
      if mod.log then
        mod.log("error","Gen 3 UI item-target Party renderer failed: "
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
      and featureEnabled("revampedOverworldMenus") then
    State.activeBagActionMenu=bagActionTop
    local bag=bagStateForMenu(game)

    if bag then
      local okBagBg,errBagBg=pcall(drawBagFinal,game,bag)
      if (not okBagBg) and mod.log then
        mod.log("error","Gen 3 UI Bag action background failed: "..tostring(errBagBg))
      end

      local okAction,errAction=pcall(GoldCompat.drawBagActionFinal,game,bagActionTop)
      if (not okAction) and mod.log then
        mod.log("error","Gen 3 UI Bag action overlay failed: "..tostring(errAction))
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
      and featureEnabled("revampedOverworldMenus")
      and not (State.activeParty and partyTopState(game,State.activeParty)) then
    local bagUnderDialogue = findBagStateInStack(game)
    if bagUnderDialogue then
      local okBagBg, errBagBg = pcall(drawBagFinal, game, bagUnderDialogue)
      if (not okBagBg) and mod.log then
        mod.log("error","Gen 3 UI live Bag underlay failed: "..tostring(errBagBg))
      end
    end
  end

  -- TM/HM Party is a persistent BACKGROUND layer. It must render before
  -- dialogue/teach overlays, because those overlays may return from this HUD pass.
  if State.activeTMParty then
    local tmBackgroundWanted =
      partyShouldRenderBehindTM(game, State.activeTMParty)
      or (State.activeTMPromptFlow and stateExistsInStack(game, State.activeTMParty))

    if featureEnabled("revampedPokemonMenu") and tmBackgroundWanted then
      local okTMParty, errTMParty = pcall(drawPartyFinal, game, State.activeTMParty)
      if (not okTMParty) and mod.log then
        mod.log("error", "Gen 3 Inspired UI Overhaul TM Party background failed: "..tostring(errTMParty))
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


  return false
end

function GoldCompat.renderHudDialogueLayer(mod,game)
  -- Dialogue/choices were marked by their native draw calls earlier this frame.
  -- Render ONLY the themed version now, outside the palette compositor.
  local drewDialogue = false

  if State.activeDialogueBox and featureEnabled("revampedDialogueBoxes") then
    local box = State.activeDialogueBox
    State.activeDialogueBox = nil

    local okDialogue, errDialogue = pcall(GoldCompat.drawDialogueThemeFinal, box)
    if not okDialogue then
      if mod.log then
        mod.log("error","Gen 3 UI final dialogue overlay failed: "..tostring(errDialogue))
      end
    end
    drewDialogue=okDialogue
  else
    State.activeDialogueBox = nil
  end

  if State.activeChoiceBox and featureEnabled("revampedDialogueBoxes") then
    local choice = State.activeChoiceBox
    State.activeChoiceBox = nil

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
        mod.log("error","Gen 3 UI battle choice prompt failed: "..tostring(errPrompt))
      end
    end

    local okChoice, errChoice = pcall(GoldCompat.drawChoiceThemeFinal, choice)
    if (not okChoice) and mod.log then
      mod.log("error","Gen 3 UI final choice overlay failed: "..tostring(errChoice))
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
    mod.log("error","Gen 3 UI Gold overlay failed ("..tostring(kind).."): "..tostring(err))
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
        and featureEnabled("revampedLevelUpUI") then
      local ok,err=pcall(GoldCompat.drawGen1LevelUpBox,
        State.activeGen1LevelUpBox)
      if not ok and mod.log then
        mod.log("error","Gen 1 level-up box failed: "..tostring(err))
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
          mod.log("error","Gen 1 hanging Options failed: "..tostring(err))
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
          mod.log("error","Gen 1 hanging Mod Manager failed: "..tostring(err))
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
          mod.log("error","Gen 1 hanging Trainer Card failed: "..tostring(err))
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
      mod.log("error","Gen 3 Inspired UI Overhaul START renderer failed: "..tostring(errStart))
    end
    return true
  elseif State.activeStartMenu then
    State.activeStartMenu = nil
  end

  if State.activeBagMenu and uiTopState(game, State.activeBagMenu) then
    local okBag, errBag = pcall(drawBagFinal, game, State.activeBagMenu)
    if (not okBag) and mod.log then
      mod.log("error","Gen 3 Inspired UI Overhaul Bag renderer failed: "..tostring(errBag))
    end
    return true
  elseif State.activeBagMenu then
    State.activeBagMenu = nil
  end

  -- STATS / MOVES use the engine's native SummaryMenu state and input.
  -- Only its presentation is replaced here.
  if DexUI.summary then
    if topState(game)==DexUI.summary
        and featureEnabled("revampedPokemonMenu") then
      local okSummary,errSummary=pcall(DexUI.drawPartySummary,game,DexUI.summary)
      if not okSummary and mod.log then
        mod.log("error","Gen 3 UI Summary renderer failed: "..tostring(errSummary))
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
      mod.log("error", "Gen 3 Inspired UI Overhaul party renderer failed: "..tostring(errParty))
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
      and featureEnabled("revampedBattleUI") then
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
      mod.log("error","Gen 3 UI battle MoveLearn renderer failed: "..tostring(err))
    end
    return true
  elseif State.activeBattleMoveLearn and not stateExistsInStack(game,State.activeBattleMoveLearn) then
    State.activeBattleMoveLearn=nil
  end

  local battle = State.activeBattle
  if not featureEnabled("revampedBattleUI") then
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
      mod.log("error", "Gen 3 Inspired UI Overhaul status HUD failed: "..tostring(errStatus))
    end
    if not okUI then
      mod.log("error", "Gen 3 Inspired UI Overhaul battle UI failed: "..tostring(errUI))
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

local Installers = {}
Installers.installVerifiedOptions = installVerifiedOptions
Installers.installPCIntegration = installPCIntegration
Installers.installMartUI = installMartUI
Installers.installDialogueThemeDirect = installDialogueThemeDirect
Installers.handleModOptionChanged = handleModOptionChanged
Installers.patchVanillaTextDrawing = patchVanillaTextDrawing
Installers.installOverworldUI = installOverworldUI
Installers.installGoldBattlePresentation = GoldCompat.installGoldBattlePresentation

return function(mod)
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
  local baHandle = mod.find and mod.find("BATTLE_ART_VOXEL_FORK") or nil
  local baPresentation = baHandle and baHandle.exports
      and baHandle.exports.battlePresentation or nil
  local baNativeContract = baPresentation
      and tonumber(baPresentation.apiVersion or 0) >= 1

  -- Install native lifecycle-preserving suppression on classic/non-BA paths.
  -- The hard HIDE NATIVE BATTLE UI option also needs this wrapper available
  -- even when another presentation mod owns normal suppression.
  Installers.patchVanillaTextDrawing()
  if baNativeContract and mod.log then
    mod.log:info("Gen 3 UI: using Battle Arts 1.8 native presentation contract")
  end

  -- Dramaless Shape captures the native HUD into its 3D battle canvas before
  -- render.hud. Disable only that legacy HUD-snap compositor while our battle
  -- UI owns presentation (or when the hard hide switch is enabled). Dramaless
  -- keeps full ownership of arena, camera, sprites, lighting and world render.
  local dramaHandle=GoldCompat.generation=="gen1"
      and mod.find and mod.find("DRAMALESS_SHAPE") or nil
  local dramaV=dramaHandle and dramaHandle.exports and dramaHandle.exports.lib
  if dramaV and type(dramaV.require)=="function" then
    local okDrama,OverworldBattle=pcall(dramaV.require,"OverworldBattle")
    if okDrama and OverworldBattle and type(OverworldBattle.snapHUDs)=="function"
        and not OverworldBattle.__gen3uiSnapPatched then
      OverworldBattle.__gen3uiSnapPatched=true
      local originalSnapHUDs=OverworldBattle.snapHUDs
      OverworldBattle.snapHUDs=function(battle,shot)
        if featureEnabled("revampedBattleUI")
            or featureEnabled("hideNativeBattleUI") then
          return false
        end
        return originalSnapHUDs(battle,shot)
      end

      -- Dramaless has a second, independent glass-panel pass used when its HUD
      -- is not snapped. If the HUD capture is suppressed but this survives,
      -- it leaves the large empty gray rectangle seen behind our command UI.
      if type(OverworldBattle.drawHudPanels)=="function" then
        local originalDrawHudPanels=OverworldBattle.drawHudPanels
        OverworldBattle.drawHudPanels=function(battle,...)
          if featureEnabled("revampedBattleUI")
              or featureEnabled("hideNativeBattleUI") then
            return
          end
          return originalDrawHudPanels(battle,...)
        end
      end

      if mod.log then
        mod.log:info("Gen 3 UI: Dramaless Shape battle-HUD compatibility active")
      end
    end
  end

  -- Dramatic Shape 1.8.x compatibility is intentionally isolated.
  -- If DRAMATIC_SHAPE is not active, this block does absolutely nothing.
  local dramaticHandle=GoldCompat.generation=="gen1"
      and mod.find and mod.find("DRAMATIC_SHAPE") or nil
  local dramaticV=dramaticHandle and dramaticHandle.exports
      and dramaticHandle.exports.lib or nil
  if dramaticV and type(dramaticV.require)=="function" then
    local okDramatic,OverworldBattle=pcall(dramaticV.require,"OverworldBattle")
    if okDramatic and OverworldBattle
        and type(OverworldBattle.snapHUDs)=="function"
        and not OverworldBattle.__gen3uiDramaticPatched then
      OverworldBattle.__gen3uiDramaticPatched=true

      local originalDramaticSnap=OverworldBattle.snapHUDs
      OverworldBattle.snapHUDs=function(battle,shot)
        if featureEnabled("revampedBattleUI")
            or featureEnabled("hideNativeBattleUI") then
          return false
        end
        return originalDramaticSnap(battle,shot)
      end

      if type(OverworldBattle.drawHudPanels)=="function" then
        local originalDramaticPanels=OverworldBattle.drawHudPanels
        OverworldBattle.drawHudPanels=function(battle,...)
          if featureEnabled("revampedBattleUI")
              or featureEnabled("hideNativeBattleUI") then
            return
          end
          return originalDramaticPanels(battle,...)
        end
      end

      if mod.log then
        mod.log:info("Gen 3 UI: Dramatic Shape 1.8 battle-HUD compatibility active")
      end
    end
  end

  if GoldCompat.generation=="gen1" then
    Installers.installOverworldUI(mod)
    GoldCompat.installGen1ModernScreens()
  else
    GoldCompat.installCoreMenuUI()
    GoldCompat.installGoldServiceUI()
    GoldCompat.installPokegearUI()
    Installers.installGoldBattlePresentation()
  end

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
