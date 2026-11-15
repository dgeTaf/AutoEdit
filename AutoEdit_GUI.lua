-- AutoEdit : calage automatique des attaques de guitare / basse (DI) sur la grille de tempo du projet.
-- Fenêtre ReaImGui. Nécessite ReaImGui (ReaPack) et Python 3 avec numpy, scipy, soundfile.
-- Lancer par AutoEdit.lua. Documentation : LISEZMOI.md, docs/UTILISATION.md, docs/ALGORITHME.md.
--
-- Réglage :
local PYTHON = ""        -- "" : détection automatique (python.exe de l'utilisateur, sinon "py -3"), ou chemin explicite

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("AutoEdit a besoin de l'extension ReaImGui.\n\nExtensions > ReaPack > Browse packages, " ..
    "cherchez \"ReaImGui\", installez-la puis redémarrez Reaper.", "AutoEdit", 0)
  return
end

local function script_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*[/\\])") or ""
end
local DIR = script_dir()
local core = dofile(DIR .. "AutoEdit_core.lua")
local R = dofile(DIR .. "AutoEdit_reaper.lua")
local T = dofile(DIR .. "AutoEdit_theme.lua")
R.init(core)
local C = T.C
local sep = package.config:sub(1, 1)
PYTHON = R.find_python(PYTHON)
local EXT = "AutoEdit"

-- ------------------------------------------------------------------ réglages (mémorisés)
local opts = {}
for k, v in pairs(core.DEFAULTS) do opts[k] = v end
opts.levels = {}
for k, v in pairs(core.DEFAULTS.levels) do opts.levels[k] = v end

local function load_opts()
  local function num(key, def)
    local v = tonumber(reaper.GetExtState(EXT, key))
    return v or def
  end
  opts.strength = num("strength", opts.strength)
  opts.max_ms = num("max_ms", opts.max_ms)
  opts.win_frac = num("win_frac", opts.win_frac)
  opts.xf_ms = num("xf_ms", opts.xf_ms)
  opts.move_doubtful = reaper.GetExtState(EXT, "move_doubtful") == "1"
  for _, l in ipairs(core.LEVELS) do
    local v = reaper.GetExtState(EXT, "lvl_" .. l.key)
    if v ~= "" then opts.levels[l.key] = v == "1" end
  end
end
local function save_opts()
  reaper.SetExtState(EXT, "strength", tostring(opts.strength), true)
  reaper.SetExtState(EXT, "max_ms", tostring(opts.max_ms), true)
  reaper.SetExtState(EXT, "win_frac", tostring(opts.win_frac), true)
  reaper.SetExtState(EXT, "xf_ms", tostring(opts.xf_ms), true)
  reaper.SetExtState(EXT, "move_doubtful", opts.move_doubtful and "1" or "0", true)
  for _, l in ipairs(core.LEVELS) do reaper.SetExtState(EXT, "lvl_" .. l.key, opts.levels[l.key] and "1" or "0", true) end
end
load_opts()

-- ------------------------------------------------------------------ état
local pending = {}                    -- actions Reaper différées : jamais pendant le dessin
local function later(fn) pending[#pending + 1] = fn end
local session = { history = {}, copies = {}, rpp_done = false }
local A = nil                         -- analyse en cours / affichée : { sel0, sel1, grid, tracks, overrides }
local job = nil                       -- export + moteur
local status, status_col = "Sélectionnez des pistes et une sélection de temps, puis Analyser.", C.muted
local cur = 1                         -- piste affichée dans le tableau
local dirty = true

local REPL = { ["≈"] = "~", ["…"] = "...", ["œ"] = "oe", ["—"] = "-", ["–"] = "-", ["−"] = "-", ["’"] = "'" }
local function clean(s)
  s = tostring(s or "")
  for k, v in pairs(REPL) do s = s:gsub(k, v) end
  return s
end
local function set_status(s, col) status, status_col = clean(s), col or C.muted end

local KINDS = { "guitar", "bass" }
local KIND_LABEL = { guitar = "Guitare", bass = "Basse" }
local LEVEL_ITEMS = "Auto\0"
for _, l in ipairs(core.LEVELS) do LEVEL_ITEMS = LEVEL_ITEMS .. l.label .. "\0" end

local ST = {
  move = { "à déplacer", C.accent }, small = { "déjà calée", C.green }, offgrid = { "hors grille", C.gray },
  irregular = { "mesure irrégulière", C.yellow },
  doubtful = { "douteuse", C.orange }, user = { "décochée", C.faint }, blocked = { "bloquée", C.red },
  join = { "raccord", C.faint }, outside = { "hors sélection", C.faint },
}

-- empreinte des items analysés : refuse d'appliquer si le projet a changé depuis l'analyse
local function fingerprint(tr_list)
  local parts = {}
  for _, tt in ipairs(tr_list) do
    for _, x in ipairs(tt.t.items) do
      if not reaper.ValidatePtr(x.it, "MediaItem*") then return "?" end
      local tk = reaper.GetActiveTake(x.it)
      parts[#parts + 1] = string.format("%.6f/%.6f/%.6f", reaper.GetMediaItemInfo_Value(x.it, "D_POSITION"),
        reaper.GetMediaItemInfo_Value(x.it, "D_LENGTH"), tk and reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") or 0)
    end
  end
  return table.concat(parts, ";")
end

-- ------------------------------------------------------------------ calculs (rapides, refaits à chaque réglage)
local function items_onsets(tt, x)
  local list = {}
  local fi = reaper.GetMediaItemInfo_Value(x.it, "D_FADEINLEN")
  for _, o in ipairs(tt.onsets) do
    if o.t >= x.pos + math.min(fi, 0.005) and o.t < x.pos + x.len then list[#list + 1] = o end
  end
  return list
end

local function recompute()
  if not A then return end
  for _, tt in ipairs(A.tracks) do
    if tt.onsets then
      local lv = core.choose_levels(tt.onsets, A.grid, opts)
      for i, ov in pairs(A.overrides) do
        if lv[i] then lv[i] = { key = ov, ratio = lv[i].ratio, n = lv[i].n, forced = true, irregular = false } end
      end
      tt.levels = lv
      core.proposals(tt.onsets, A.grid, lv, { strength = tt.strength, target_ms = tt.target_ms, enabled = tt.enabled },
        opts, A.sel0, A.sel1)
      -- plan de coupe par item : notes bloquées affichées avant l'application
      tt.plans, tt.n_blocked = {}, 0
      for _, o in ipairs(tt.onsets) do o.blocked = nil end
      for _, x in ipairs(tt.t.items) do
        local list = items_onsets(tt, x)
        local plan = core.plan_item({ pos = x.pos, len = x.len }, list, opts)
        for i, why in pairs(plan.blocked) do
          list[i].blocked = why
          tt.n_blocked = tt.n_blocked + 1
        end
        tt.plans[#tt.plans + 1] = { x = x, plan = plan }
      end
      local c = { move = 0, sure = 0, offgrid = 0, doubtful = 0, n = 0 }
      for _, o in ipairs(tt.onsets) do
        if o.status ~= "outside" and o.status ~= "join" then
          c.n = c.n + 1
          if o.sure then c.sure = c.sure + 1 end
          if o.status == "move" and not o.blocked then c.move = c.move + 1 end
          if o.status == "offgrid" or o.status == "irregular" then c.offgrid = c.offgrid + 1 end
          if o.status == "doubtful" then c.doubtful = c.doubtful + 1 end
        end
      end
      tt.count = c
    end
  end
  dirty = false
end

-- ------------------------------------------------------------------ analyse
local function start_analysis()
  if job then return end
  local s, e = R.get_selection()
  if not s then return set_status("Faites d'abord une sélection de temps (le riff à caler).", C.red) end
  local n = reaper.CountSelectedTracks(0)
  if n == 0 then return set_status("Sélectionnez au moins une piste (guitare ou basse).", C.red) end
  if not R.read_file(R.ENGINE) then return set_status("ae_engine.py introuvable : " .. R.ENGINE, C.red) end
  local proj_dir = reaper.GetProjectPath("")
  local dir = proj_dir .. sep .. "AutoEdit"
  reaper.RecursiveCreateDirectory(dir, 0)
  local list, skipped = {}, {}
  local old = {}
  if A then for _, tt in ipairs(A.tracks) do old[tt.t.guid] = tt end end
  for i = 0, n - 1 do
    local tr = reaper.GetSelectedTrack(0, i)
    local t = R.scan_track(tr, s, e)
    if #t.problems > 0 then
      skipped[#skipped + 1] = t.name .. " (" .. table.concat(t.problems, ", ") .. ")"
    elseif #t.items == 0 then
      skipped[#skipped + 1] = t.name .. " (aucun item dans la sélection)"
    else
      local prev = old[t.guid]
      list[#list + 1] = { t = t, kind = prev and prev.kind or R.guess_kind(t.name), strength = prev and prev.strength,
                          target_ms = prev and prev.target_ms or 0, enabled = {}, side = R.side(tr, t.name) }
    end
  end
  if #list == 0 then
    return set_status("Aucune piste traitable. Ignorées : " .. table.concat(skipped, " ; "), C.red)
  end
  -- doublures gauche / droite : force plus basse proposée pour garder l'effet de double
  local guit_l, guit_r = 0, 0
  for _, tt in ipairs(list) do
    if tt.kind == "guitar" and tt.side < 0 then guit_l = guit_l + 1 end
    if tt.kind == "guitar" and tt.side > 0 then guit_r = guit_r + 1 end
  end
  for _, tt in ipairs(list) do
    if not tt.strength then
      tt.double = tt.kind == "guitar" and tt.side ~= 0 and guit_l > 0 and guit_r > 0
      tt.strength = tt.double and math.min(opts.strength, 0.7) or opts.strength
    end
  end
  local exports = {}
  for i, tt in ipairs(list) do exports[i] = R.export_begin(tt.t, s, e, dir, i) tt.ex = exports[i] end
  job = { stage = "export", s = s, e = e, dir = dir, list = list, exports = exports, k = 1 }
  A = nil
  set_status(#skipped > 0 and ("Ignorées : " .. table.concat(skipped, " ; ")) or "Lecture de l'audio des pistes...",
    #skipped > 0 and C.orange or C.muted)
  job.skipped = skipped
end

local function finish_analysis(res)
  local grid = core.build_grid(job.s, job.e, R.tm)
  local a = { sel0 = job.s, sel1 = job.e, grid = grid, tracks = job.list, overrides = {}, skipped = job.skipped }
  for i, tt in ipairs(job.list) do
    local r = res.items and res.items[tostring(i)]
    tt.onsets = r and R.track_onsets(tt.t, tt.ex, r) or {}
    core.match(tt.onsets, grid)
    tt.ex.buf = nil
  end
  a.fp = fingerprint(a.tracks)
  A, job, cur, dirty = a, nil, 1, true
  local msg = string.format("Analyse terminée : %d piste(s), %d mesures.", #a.tracks, #grid)
  if #(a.skipped or {}) > 0 then msg = msg .. " Ignorées : " .. table.concat(a.skipped, " ; ") end
  set_status(msg, C.green)
end

local function tick_job()
  if not job then return end
  if job.stage == "export" then
    local ex = job.exports[job.k]
    if R.export_step(ex, R.FRAME_BUDGET) then
      R.write_wav(ex.wav, ex.buf, R.FS)
      job.k = job.k + 1
      if job.k > #job.exports then
        local entries = {}
        for i, tt in ipairs(job.list) do entries[i] = { id = tostring(i), wav = tt.ex.wav, kind = tt.kind } end
        R.write_job(job.dir .. sep .. "job.json", entries)
        job.p = R.launch(PYTHON, job.dir)
        job.stage = "engine"
      end
    end
    local done = 0
    for i = 1, job.k - 1 do done = done + #job.exports[i].tasks end
    local total = 0
    for _, x in ipairs(job.exports) do total = total + #x.tasks end
    if job.exports[job.k] then done = done + job.exports[job.k].done end
    job.progress = string.format("Lecture de l'audio (avant effets) : %d %%", math.floor(100 * done / math.max(1, total)))
  elseif job.stage == "engine" then
    local st, r = R.poll(job.p)
    if st == "done" then
      finish_analysis(r)
    elseif st == "error" then
      set_status("Erreur du moteur Python :\n" .. tostring(r), C.red)
      job = nil
    else
      job.progress = "Détection des attaques (Python)... " .. clean(job.p.progress or "")
    end
  end
end

local function cancel_job()
  if job and job.exports then for _, ex in ipairs(job.exports) do R.export_abort(ex) end end
  job = nil
end

-- ------------------------------------------------------------------ application / retour
local function apply_now()
  if not A then return end
  if fingerprint(A.tracks) ~= A.fp then
    return set_status("Les items ont changé depuis l'analyse : relancez l'analyse avant d'appliquer.", C.red)
  end
  recompute()
  local plans, n_move, n_blocked = {}, 0, 0
  for _, tt in ipairs(A.tracks) do
    if tt.plans then
      plans[#plans + 1] = { t = tt.t, items = tt.plans }
      n_move = n_move + (tt.count and tt.count.move or 0)
      n_blocked = n_blocked + (tt.n_blocked or 0)
    end
  end
  if n_move == 0 then return set_status("Rien à déplacer avec ces réglages.", C.orange) end
  if not session.rpp_done then
    local ok, msg = R.backup_rpp()
    if not ok then return set_status("Application annulée : " .. msg, C.orange) end
    session.rpp_done, session.rpp = true, msg
  end
  local ok, entry, n_cuts, n_items = pcall(R.apply, plans, opts, session)
  if not ok then return set_status("Erreur pendant l'application (annulable par Ctrl+Z) : " .. tostring(entry), C.red) end
  session.history[#session.history + 1] = entry
  A = nil
  set_status(string.format("Appliqué : %d attaques calées, %d coupes sur %d item(s)%s. Copie du projet : %s. " ..
    "Relancez l'analyse pour vérifier.", n_move, n_cuts, n_items,
    n_blocked > 0 and string.format(", %d notes bloquées (trop rapprochées)", n_blocked) or "",
    session.rpp or "aucune"), C.green)
end

local function revert_all()
  local miss = 0
  for i = #session.history, 1, -1 do
    local ok, m = pcall(R.revert, session.history[i])
    if not ok then return set_status("Erreur pendant le retour arrière : " .. tostring(m), C.red) end
    miss = miss + m
    session.history[i] = nil
  end
  A = nil
  set_status("Retour à l'état d'avant fait" .. (miss > 0 and string.format(" (%d piste(s) introuvable(s))", miss) or "") ..
    ". Les pistes « AutoEdit original » restent (muettes) : supprimez-les quand vous voulez.", C.green)
end

-- ------------------------------------------------------------------ dessin
local ctx = reaper.ImGui_CreateContext("AutoEdit")
T.init(ctx)

local function begin_disabled(flag) if reaper.ImGui_BeginDisabled then reaper.ImGui_BeginDisabled(ctx, flag) end end
local function end_disabled() if reaper.ImGui_EndDisabled then reaper.ImGui_EndDisabled(ctx) end end
local function tip(s)
  if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, clean(s)) end
end

local function draw_header()
  T.begin_card(ctx, "head")
  T.text(ctx, "title", C.title, "AutoEdit")
  reaper.ImGui_SameLine(ctx)
  T.text(ctx, "small", C.muted, "  calage des attaques DI sur la grille de tempo du projet")
  begin_disabled(job ~= nil)
  if T.accent_button(ctx, "Analyser les pistes sélectionnées") then later(start_analysis) end
  end_disabled()
  tip("Lit l'audio des takes (avant les effets de piste) dans la sélection de temps, détecte les attaques.")
  reaper.ImGui_SameLine(ctx)
  begin_disabled(not A or job ~= nil)
  if T.button(ctx, "Appliquer", C.green) then later(apply_now) end
  end_disabled()
  tip("Coupe avant chaque attaque à déplacer, déplace la tranche, fondus de raccord.\n" ..
    "Avant la 1re application : copie datée du .rpp et pistes muettes « AutoEdit original ».\nAnnulable par Ctrl+Z.")
  reaper.ImGui_SameLine(ctx)
  begin_disabled(#session.history == 0 or job ~= nil)
  if T.button(ctx, string.format("Revenir à l'état d'avant (%d)", #session.history), C.red) then later(revert_all) end
  end_disabled()
  tip("Annule toutes les applications de cette session (items d'origine recréés).")
  if job then
    reaper.ImGui_SameLine(ctx)
    if T.button(ctx, "Arrêter") then later(cancel_job) end
    T.text(ctx, "small", C.accent, clean(job.progress or "..."))
  end
  T.text(ctx, "small", status_col, status)
  T.end_card(ctx)
end

local function draw_settings()
  T.begin_card(ctx, "set")
  T.label(ctx, "RÉGLAGES")
  local ch, v
  reaper.ImGui_SetNextItemWidth(ctx, 160)
  ch, v = reaper.ImGui_SliderDouble(ctx, "Force", opts.strength * 100, 0, 100, "%.0f %%")
  if ch then
    local old = opts.strength
    opts.strength = v / 100
    if A then for _, tt in ipairs(A.tracks) do
      if tt.double then tt.strength = math.min(tt.strength * (old > 0 and opts.strength / old or 1), 1)
      else tt.strength = opts.strength end
    end end
    dirty = true later(save_opts)
  end
  tip("Part de l'écart corrigée : 100 % = sur la ligne (plus le décalage voulu de la piste).")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 140)
  ch, v = reaper.ImGui_SliderDouble(ctx, "Écart max", opts.max_ms, 5, 60, "%.0f ms")
  if ch then opts.max_ms = v dirty = true later(save_opts) end
  tip("Au-delà, la note est considérée hors grille (syncope, swing) et reste intacte.")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 140)
  ch, v = reaper.ImGui_SliderDouble(ctx, "Fenêtre", opts.win_frac * 100, 10, 50, "%.0f %% de l'écart")
  if ch then opts.win_frac = v / 100 dirty = true later(save_opts) end
  tip("Fenêtre d'appariement : fraction de l'écart entre deux lignes de la subdivision.")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 120)
  ch, v = reaper.ImGui_SliderDouble(ctx, "Fondu", opts.xf_ms, 1, 10, "%.1f ms")
  if ch then opts.xf_ms = v dirty = true later(save_opts) end
  T.label(ctx, "SUBDIVISIONS POSSIBLES (choix automatique par mesure : la plus grossière qui couvre 75 % des attaques)")
  for i, l in ipairs(core.LEVELS) do
    if i > 1 then reaper.ImGui_SameLine(ctx) end
    ch, v = reaper.ImGui_Checkbox(ctx, l.label, opts.levels[l.key])
    if ch then opts.levels[l.key] = v dirty = true later(save_opts) end
  end
  ch, v = reaper.ImGui_Checkbox(ctx, "Déplacer aussi les attaques douteuses", opts.move_doubtful)
  if ch then opts.move_doubtful = v dirty = true later(save_opts) end
  tip("Douteuse : attaque peu nette (la note d'avant sonne encore, note liée) ; sa position est approximative.")
  T.end_card(ctx)
end

local function draw_tracks()
  if not A then return end
  T.begin_card(ctx, "tracks")
  T.label(ctx, "PISTES")
  local flags = reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_BordersInnerH()
  if reaper.ImGui_BeginTable(ctx, "trk", 6, flags, T.card_w(), 0) then
    reaper.ImGui_TableSetupColumn(ctx, "Piste", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Type", reaper.ImGui_TableColumnFlags_WidthFixed(), 110)
    reaper.ImGui_TableSetupColumn(ctx, "Force", reaper.ImGui_TableColumnFlags_WidthFixed(), 130)
    reaper.ImGui_TableSetupColumn(ctx, "Décalage voulu", reaper.ImGui_TableColumnFlags_WidthFixed(), 130)
    reaper.ImGui_TableSetupColumn(ctx, "Attaques", reaper.ImGui_TableColumnFlags_WidthFixed(), 300)
    reaper.ImGui_TableSetupColumn(ctx, "", reaper.ImGui_TableColumnFlags_WidthFixed(), 50)
    reaper.ImGui_TableHeadersRow(ctx)
    for i, tt in ipairs(A.tracks) do
      reaper.ImGui_PushID(ctx, i)
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      if reaper.ImGui_Selectable(ctx, clean(tt.t.name), cur == i) then cur = i end
      if tt.double then
        reaper.ImGui_SameLine(ctx)
        T.chip(ctx, tt.side < 0 and "doublure G" or "doublure D", C.purple)
        tip("Doublure gauche / droite : force réduite proposée pour garder l'effet de double.")
      end
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 100)
      local ki = tt.kind == "bass" and 1 or 0
      local ch, v = reaper.ImGui_Combo(ctx, "##kind", ki, "Guitare\0Basse\0")
      if ch then
        tt.kind = KINDS[v + 1]
        set_status("Type changé : relancez l'analyse (la détection dépend du type).", C.orange)
      end
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 120)
      ch, v = reaper.ImGui_SliderDouble(ctx, "##str", tt.strength * 100, 0, 100, "%.0f %%")
      if ch then tt.strength = v / 100 dirty = true end
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 120)
      ch, v = reaper.ImGui_DragDouble(ctx, "##tgt", tt.target_ms, 0.1, -20, 20, "%+.1f ms")
      if ch then tt.target_ms = v dirty = true end
      tip("Position voulue par rapport à la ligne : + = en arrière (ex. basse +2 ms), - = en avant.")
      reaper.ImGui_TableNextColumn(ctx)
      local c = tt.count
      if c then
        T.text(ctx, "small", C.text, string.format("%d : %d à caler, %d hors grille, %d douteuses%s", c.n, c.move,
          c.offgrid, c.doubtful, (tt.n_blocked or 0) > 0 and string.format(", %d bloquées", tt.n_blocked) or ""))
      end
      reaper.ImGui_TableNextColumn(ctx)
      if T.button(ctx, "Voir") then cur = i end
      reaper.ImGui_PopID(ctx)
    end
    reaper.ImGui_EndTable(ctx)
  end
  T.end_card(ctx)
end

local function draw_measures(tt)
  T.begin_card(ctx, "meas")
  T.label(ctx, "MESURES : subdivision choisie pour « " .. clean(tt.t.name) .. " » (le choix forcé vaut pour toutes les pistes)")
  local flags = reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_BordersInnerH()
  if reaper.ImGui_BeginTable(ctx, "meas", 4, flags, T.card_w(), 0) then
    reaper.ImGui_TableSetupColumn(ctx, "Mesure", reaper.ImGui_TableColumnFlags_WidthFixed(), 90)
    reaper.ImGui_TableSetupColumn(ctx, "Signature", reaper.ImGui_TableColumnFlags_WidthFixed(), 80)
    reaper.ImGui_TableSetupColumn(ctx, "Subdivision", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Forcer", reaper.ImGui_TableColumnFlags_WidthFixed(), 190)
    reaper.ImGui_TableHeadersRow(ctx)
    for i, ms in ipairs(A.grid) do
      local lv = tt.levels and tt.levels[i] or {}
      reaper.ImGui_PushID(ctx, i)
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      if reaper.ImGui_Selectable(ctx, tostring(ms.idx + 1), false) then
        local t0 = ms.t0
        later(function() reaper.SetEditCurPos(t0, true, false) end)
      end
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, string.format("%d/%d", ms.num, ms.den))
      reaper.ImGui_TableNextColumn(ctx)
      if lv.key then
        local l = core.LEVELS[core.LEVEL_INDEX[lv.key]]
        local col = lv.irregular and C.orange or (lv.forced and C.purple or C.text)
        T.text(ctx, "body", col, clean(string.format("%s  (%d attaques, %.0f %% dans la fenêtre)%s%s", l.label, lv.n or 0,
          100 * (lv.ratio or 0), lv.irregular and " : irrégulière, rien n'est déplacé sans choix forcé" or "",
          lv.forced and " (forcée)" or "")))
      else
        T.text(ctx, "body", C.faint, "aucune attaque sûre")
      end
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 180)
      local cur_ov = A.overrides[i] and core.LEVEL_INDEX[A.overrides[i]] or 0
      local ch, v = reaper.ImGui_Combo(ctx, "##ov", cur_ov, LEVEL_ITEMS)
      if ch then A.overrides[i] = v > 0 and core.LEVELS[v].key or nil dirty = true end
      reaper.ImGui_PopID(ctx)
    end
    reaper.ImGui_EndTable(ctx)
  end
  T.end_card(ctx)
end

local function status_of(o)
  if o.blocked then return ST.blocked end
  return ST[o.status] or ST.offgrid
end

local function draw_graph(tt)
  T.begin_card(ctx, "graph")
  T.label(ctx, "ÉCARTS À LA GRILLE (ms, + = en retard) : point = position actuelle, trait = déplacement proposé")
  local w, h = T.card_w(), 170
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, "##graph", w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local clicked = reaper.ImGui_IsItemClicked(ctx, 0)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local span = math.max(1e-3, A.sel1 - A.sel0)
  local ymax = opts.max_ms
  local function X(t) return x0 + (t - A.sel0) / span * w end
  local function Y(ms) return y0 + h / 2 - math.max(-1, math.min(1, ms / ymax)) * (h / 2 - 6) end
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, C.field, 6)
  for _, ms in ipairs(A.grid) do
    if ms.t0 >= A.sel0 and ms.t0 <= A.sel1 then
      reaper.ImGui_DrawList_AddLine(dl, X(ms.t0), y0, X(ms.t0), y0 + h, C.border, 1)
    end
  end
  reaper.ImGui_DrawList_AddLine(dl, x0, Y(0), x0 + w, Y(0), C.faint, 1)
  reaper.ImGui_DrawList_AddText(dl, x0 + 4, y0 + 2, C.muted, string.format("+%.0f ms", ymax))
  reaper.ImGui_DrawList_AddText(dl, x0 + 4, y0 + h - 16, C.muted, string.format("-%.0f ms", ymax))
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  local best, bd = nil, 12
  for i, o in ipairs(tt.onsets) do
    if o.status ~= "outside" and o.off_ms then
      local st = status_of(o)
      local px, py = X(o.t), Y(o.off_ms)
      if o.status == "move" and not o.blocked then
        local tgt = o.off_ms + o.shift * 1000
        reaper.ImGui_DrawList_AddLine(dl, px, py, px, Y(tgt), T.alpha(C.accent, 0.5), 2)
      end
      reaper.ImGui_DrawList_AddCircleFilled(dl, px, py, o.sure and 3.5 or 2.5, st[2])
      local d = math.abs(mx - px) + math.abs(my - py)
      if hovered and d < bd then best, bd = i, d end
    end
  end
  if best then
    local o = tt.onsets[best]
    reaper.ImGui_SetTooltip(ctx, clean(string.format("%s  écart %+.1f ms, proposé %+.1f ms (%s)", core.fmt_pos(R.tm, o.t),
      o.off_ms or 0, (o.shift or 0) * 1000, status_of(o)[1])))
    if clicked then
      local t = o.t
      later(function() reaper.SetEditCurPos(t, true, false) end)
    end
  end
  T.end_card(ctx)
end

local function draw_table(tt)
  T.begin_card(ctx, "tbl")
  T.label(ctx, "ATTAQUES DE « " .. clean(tt.t.name) .. " » (clic sur la position : curseur d'édition à l'attaque)")
  local flags = reaper.ImGui_TableFlags_RowBg() | reaper.ImGui_TableFlags_BordersInnerH()
  if reaper.ImGui_BeginTable(ctx, "att", 6, flags, T.card_w(), 0) then
    reaper.ImGui_TableSetupColumn(ctx, "", reaper.ImGui_TableColumnFlags_WidthFixed(), 28)
    reaper.ImGui_TableSetupColumn(ctx, "Position", reaper.ImGui_TableColumnFlags_WidthFixed(), 110)
    reaper.ImGui_TableSetupColumn(ctx, "Subdivision", reaper.ImGui_TableColumnFlags_WidthFixed(), 150)
    reaper.ImGui_TableSetupColumn(ctx, "Écart actuel", reaper.ImGui_TableColumnFlags_WidthFixed(), 100)
    reaper.ImGui_TableSetupColumn(ctx, "Proposé", reaper.ImGui_TableColumnFlags_WidthFixed(), 90)
    reaper.ImGui_TableSetupColumn(ctx, "État", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableHeadersRow(ctx)
    for i, o in ipairs(tt.onsets) do
      if o.status ~= "outside" then
        reaper.ImGui_PushID(ctx, i)
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableNextColumn(ctx)
        local can = o.status == "move" or o.status == "user"
        begin_disabled(not can)
        local ch, v = reaper.ImGui_Checkbox(ctx, "##on", o.status == "move")
        end_disabled()
        if ch then tt.enabled[i] = v and nil or false dirty = true end
        reaper.ImGui_TableNextColumn(ctx)
        if reaper.ImGui_Selectable(ctx, core.fmt_pos(R.tm, o.t), false) then
          local t = o.t
          later(function() reaper.SetEditCurPos(t, true, false) end)
        end
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, o.level and core.LEVELS[core.LEVEL_INDEX[o.level]].label or "-")
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, o.off_ms and string.format("%+.1f ms", o.off_ms) or "-")
        reaper.ImGui_TableNextColumn(ctx)
        local sh = o.blocked and 0 or (o.shift or 0) * 1000
        reaper.ImGui_Text(ctx, math.abs(sh) > 0 and string.format("%+.1f ms", sh) or "-")
        reaper.ImGui_TableNextColumn(ctx)
        local st = status_of(o)
        local extra = ""
        if o.blocked then extra = " : " .. o.blocked
        elseif not o.sure then extra = string.format(" (netteté %.0f dB)", o.contrast or 0) end
        if o.amb then extra = extra .. ", ambiguë" end
        T.text(ctx, "body", st[2], clean(st[1] .. extra))
        reaper.ImGui_PopID(ctx)
      end
    end
    reaper.ImGui_EndTable(ctx)
  end
  T.end_card(ctx)
end

local function frame()
  local todo = pending
  pending = {}
  for _, fn in ipairs(todo) do
    local ok, err = pcall(fn)
    if not ok then set_status("Erreur : " .. tostring(err), C.red) end
  end
  tick_job()
  if dirty then recompute() end

  local st = T.push(ctx)
  reaper.ImGui_SetNextWindowSize(ctx, 1100, 860, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, "AutoEdit###AutoEdit", true)
  if visible then
    draw_header()
    draw_settings()
    if A then
      draw_tracks()
      local tt = A.tracks[cur] or A.tracks[1]
      if tt and tt.onsets then
        draw_graph(tt)
        draw_table(tt)
        draw_measures(tt)
      end
    end
    reaper.ImGui_End(ctx)
  end
  T.pop(ctx, st)
  if open then
    reaper.defer(frame)
  else
    cancel_job()
  end
end

-- crochet réservé aux tests (fausse API) : AUTOEDIT_TEST = { on_frame = function(api) ... end }
if AUTOEDIT_TEST then
  AUTOEDIT_TEST.api = { start = start_analysis, apply = apply_now, revert = revert_all, recompute = recompute,
    state = function() return A, job, session, status end, opts = opts }
  local inner = frame
  frame = function()
    if AUTOEDIT_TEST.on_frame then AUTOEDIT_TEST.on_frame(AUTOEDIT_TEST.api) end
    if AUTOEDIT_TEST.stop then return end
    inner()
  end
end

reaper.defer(frame)
