-- AutoEdit_reaper.lua : tout ce qui lit ou modifie le projet Reaper (sans ImGui).
--   pistes et items à traiter, export de l'audio des takes (AVANT les effets de piste) par tranches,
--   lancement du moteur Python, lecture du résultat, application des coupes, sauvegardes, retour arrière.
-- Retourne un module R. Voir docs/ALGORITHME.md (§ Application) et docs/UTILISATION.md.

local R = {}
local core               -- AutoEdit_core.lua, fourni par R.init
local sep = package.config:sub(1, 1)
local is_win = (reaper.GetOS() or ""):match("^Win") ~= nil

R.FS = 22050             -- fréquence d'export (le moteur travaille à 22050 Hz)
R.MARGIN_BEFORE = 1.0    -- s d'audio exporté avant la sélection (contexte, attaques d'ancrage)
R.MARGIN_AFTER = 0.5     -- s après la sélection (première attaque suivante = ancrage à déplacement nul)
R.FRAME_BUDGET = 0.025   -- s de calcul d'export par passage de la boucle (Reaper reste fluide)
R.JOIN_TOL = 0.003       -- attaque à moins de 3 ms d'un raccord existant : ignorée (artefact d'un calage précédent)

function R.init(core_mod) core = core_mod end

local function script_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*[/\\])") or ""
end
R.ENGINE = script_dir() .. "ae_engine.py"

-- ------------------------------------------------------------------ utilitaires
function R.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function jstr(s)
  s = tostring(s):gsub('[%c"\\]', function(c)
    local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return m[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end

local function guid_of_item(it) return select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)) end

-- Reaper garde le PATH de son lancement : on cherche python.exe nous-mêmes (version la plus récente)
function R.find_python(user)
  if user and user ~= "" then return user end
  if is_win then
    local base = (os.getenv("LOCALAPPDATA") or "") .. "\\Programs\\Python"
    local best, best_v, i = nil, -1, 0
    while true do
      local d = reaper.EnumerateSubdirectories(base, i)
      if not d then break end
      local maj, min = d:match("^Python(%d)(%d+)$")
      local exe = base .. "\\" .. d .. "\\python.exe"
      if maj == "3" and reaper.file_exists(exe) and tonumber(min) > best_v then best, best_v = exe, tonumber(min) end
      i = i + 1
    end
    if best then return '"' .. best .. '"' end
    return "py -3"
  end
  return "python3"
end

-- carte de tempo, au format attendu par AutoEdit_core (valeurs vérifiées dans Reaper 7, voir tests/probe_api_reaper.py)
R.tm = {
  measure_at = function(t) return select(2, reaper.TimeMap2_timeToBeats(0, t)) end,
  info = function(m)
    local ts, qn0, qn1, num, den = reaper.TimeMap_GetMeasureInfo(0, m)
    return ts, qn0, qn1, num, den
  end,
  qn_to_time = function(qn) return reaper.TimeMap2_QNToTime(0, qn) end,
  time_to_beats = function(t)
    local beat, meas = reaper.TimeMap2_timeToBeats(0, t)
    return beat, meas
  end,
}

function R.get_selection()
  local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if e - s > 0.05 then return s, e end
  return nil
end

-- ------------------------------------------------------------------ pistes et items
-- type deviné d'après le nom
function R.guess_kind(name)
  local n = name:lower()
  if n:match("bass") or n:match("basse") or n:match("^bas[%s_%-]") then return "bass" end
  return "guitar"
end

-- côté d'une doublure (nom ou panoramique) : -1 gauche, 1 droite, 0 inconnu
function R.side(tr, name)
  local n = name:lower()
  if n:match("left") or n:match("gauche") or n:match("[%s_%-]l$") or n:match("^l[%s_%-]") then return -1 end
  if n:match("right") or n:match("droite") or n:match("[%s_%-]r$") or n:match("^r[%s_%-]") then return 1 end
  local pan = reaper.GetMediaTrackInfo_Value(tr, "D_PAN")
  if pan <= -0.3 then return -1 elseif pan >= 0.3 then return 1 end
  return 0
end

local function item_bounds(it)
  local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
  return pos, pos + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
end

-- Items de la piste qui touchent [s, e]. Un item non traitable (MIDI, vitesse modifiée, marqueurs d'étirement,
-- verrouillé, sans take) rend la piste non traitable : on ne coupe pas à moitié un passage.
function R.scan_track(tr, s, e)
  local _, name = reaper.GetTrackName(tr)
  local t = { tr = tr, guid = reaper.GetTrackGUID(tr), name = name, items = {}, problems = {} }
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    local p0, p1 = item_bounds(it)
    if p1 > s - R.MARGIN_BEFORE and p0 < e + R.MARGIN_AFTER then
      local take = reaper.GetActiveTake(it)
      local why
      if not take then
        why = "item vide"
      elseif reaper.TakeIsMIDI(take) then
        why = "item MIDI"
      elseif math.abs(reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") - 1) > 1e-9 then
        why = "vitesse de lecture modifiée"
      elseif reaper.GetTakeNumStretchMarkers(take) > 0 then
        why = "marqueurs d'étirement"
      elseif (reaper.GetMediaItemInfo_Value(it, "C_LOCK") or 0) % 2 == 1 then
        why = "item verrouillé"
      end
      if why then
        t.problems[#t.problems + 1] = string.format("%s à %.2f s", why, p0)
      else
        t.items[#t.items + 1] = { it = it, guid = guid_of_item(it), pos = p0, len = p1 - p0, take = take }
      end
    end
  end
  table.sort(t.items, function(a, b) return a.pos < b.pos end)
  return t
end

-- ------------------------------------------------------------------ export (par tranches, sans figer Reaper)
local function fade_gain(it, x, len)
  -- gain des fondus de l'item (linéaire, approximation suffisante pour situer les attaques)
  local fi = reaper.GetMediaItemInfo_Value(it, "D_FADEINLEN_AUTO")
  if fi < 0 then fi = reaper.GetMediaItemInfo_Value(it, "D_FADEINLEN") end
  local fo = reaper.GetMediaItemInfo_Value(it, "D_FADEOUTLEN_AUTO")
  if fo < 0 then fo = reaper.GetMediaItemInfo_Value(it, "D_FADEOUTLEN") end
  local g = 1
  if fi > 0 and x < fi then g = g * x / fi end
  if fo > 0 and x > len - fo then g = g * math.max(0, (len - x) / fo) end
  return g
end

-- Prépare l'export d'une piste : tampon mono de la plage, liste des lectures à faire.
function R.export_begin(t, s, e, dir, idx)
  local r0 = s - R.MARGIN_BEFORE
  local r1 = e + R.MARGIN_AFTER
  if #t.items > 0 then
    r0 = math.max(r0, t.items[1].pos)
    local last = 0
    for _, x in ipairs(t.items) do last = math.max(last, x.pos + x.len) end
    r1 = math.min(r1, last)
  end
  local n = math.max(0, math.floor((r1 - r0) * R.FS))
  local ex = { t = t, r0 = r0, r1 = r1, n = n, buf = {}, tasks = {}, wav = dir .. sep .. string.format("track%02d.wav", idx) }
  for k = 1, n do ex.buf[k] = 0.0 end
  for _, x in ipairs(t.items) do
    local a = math.max(r0, x.pos)
    local b = math.min(r1, x.pos + x.len)
    local step = 0.5
    local u = a
    while u < b - 1e-9 do
      local v = math.min(b, u + step)
      ex.tasks[#ex.tasks + 1] = { x = x, a = u, b = v }
      u = v
    end
  end
  ex.done = 0
  return ex
end

-- Exécute des lectures jusqu'à épuiser le budget de temps. Renvoie true quand tout est lu.
function R.export_step(ex, budget)
  local t0 = reaper.time_precise()
  while ex.done < #ex.tasks do
    local task = ex.tasks[ex.done + 1]
    local x = task.x
    if not x.acc then
      x.acc = reaper.CreateTakeAudioAccessor(x.take)
      local src = reaper.GetMediaItemTake_Source(x.take)
      x.nch = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src)))
    end
    -- indices d'échantillons de la plage couverts par cette lecture
    local k0 = math.floor((task.a - ex.r0) * R.FS + 0.5)
    local k1 = math.min(ex.n, math.floor((task.b - ex.r0) * R.FS + 0.5))
    local cnt = k1 - k0
    if cnt > 0 then
      local arr = reaper.new_array(cnt * x.nch)
      -- temps de l'accessor de take : local à l'item (0 = début de l'item), vérifié dans Reaper
      local lt = ex.r0 + k0 / R.FS - x.pos
      reaper.GetAudioAccessorSamples(x.acc, R.FS, x.nch, lt, cnt, arr)
      local v = arr.table()
      local nch = x.nch
      for k = 1, cnt do
        local sm = v[(k - 1) * nch + 1]
        if nch == 2 then sm = 0.5 * (sm + v[(k - 1) * nch + 2]) end
        local local_t = lt + (k - 1) / R.FS
        ex.buf[k0 + k] = ex.buf[k0 + k] + sm * fade_gain(x.it, local_t, x.len)
      end
    end
    ex.done = ex.done + 1
    local nxt = ex.tasks[ex.done + 1]
    if not nxt or nxt.x ~= x then
      reaper.DestroyAudioAccessor(x.acc)
      x.acc = nil
    end
    if reaper.time_precise() - t0 > budget then return false end
  end
  return true
end

function R.export_abort(ex)
  for _, task in ipairs(ex.tasks) do
    if task.x.acc then reaper.DestroyAudioAccessor(task.x.acc) task.x.acc = nil end
  end
end

-- WAV mono float32
function R.write_wav(path, buf, fs)
  local f = assert(io.open(path, "wb"))
  local n = #buf
  local data = n * 4
  f:write("RIFF", string.pack("<I4", 36 + data), "WAVE", "fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 3, 1, fs, fs * 4, 4, 32),
    "data", string.pack("<I4", data))
  local CH = 2048
  local fmt = "<" .. string.rep("f", CH)
  local k = 1
  while k <= n do
    local m = math.min(CH, n - k + 1)
    if m == CH then
      f:write(string.pack(fmt, table.unpack(buf, k, k + CH - 1)))
    else
      f:write(string.pack("<" .. string.rep("f", m), table.unpack(buf, k, k + m - 1)))
    end
    k = k + m
  end
  f:close()
end

-- ------------------------------------------------------------------ moteur Python
function R.write_job(path, entries)
  local parts = {}
  for _, en in ipairs(entries) do
    parts[#parts + 1] = string.format('{"id":%s,"wav":%s,"kind":%s}', jstr(en.id), jstr(en.wav), jstr(en.kind))
  end
  local f = assert(io.open(path, "wb"))
  f:write('{"items":[' .. table.concat(parts, ",") .. ']}')
  f:close()
end

function R.launch(python, dir)
  local job, out, log = dir .. sep .. "job.json", dir .. sep .. "result.lua", dir .. sep .. "engine.log"
  os.remove(out)
  os.remove(log)
  os.remove(log .. ".err")
  os.remove(dir .. sep .. "error.txt")
  local args = string.format(' "%s" --job "%s" --out "%s" --log "%s"', R.ENGINE, job, out, log)
  local cmd
  local pyw = python:match('^"(.*)python%.exe"$')
  pyw = pyw and (pyw .. "pythonw.exe")
  if is_win and pyw and reaper.file_exists(pyw) then
    cmd = '"' .. pyw .. '"' .. args          -- direct, sans console (un Ctrl+C dans une console tuait Python)
  elseif is_win then
    cmd = 'cmd.exe /c "' .. python .. args .. ' 2>"' .. log .. '.err""'
  else
    cmd = python .. args
  end
  reaper.ExecProcess(cmd, -1)
  return { out = out, log = log, dir = dir, cmd = cmd, t0 = reaper.time_precise(), last = 0 }
end

-- Renvoie "wait" | "done", result | "error", message
function R.poll(p)
  local now = reaper.time_precise()
  if now - p.last < 0.3 then return "wait" end
  p.last = now
  local err = R.read_file(p.dir .. sep .. "error.txt")
  if err then return "error", err end
  local s = R.read_file(p.out)
  if s then
    local fn = load(s, "result", "t", {})
    if fn then
      local ok, r = pcall(fn)
      if ok and type(r) == "table" then return "done", r end
    end
  end
  local log = (R.read_file(p.log) or "") .. (R.read_file(p.log .. ".err") or "")
  if log:find("Traceback", 1, true) or log:find("No module named", 1, true) or log:find("not recognized", 1, true)
      or log:find("pas reconnu", 1, true) then
    return "error", log
  end
  p.progress = log:match("([^\r\n]+)[\r\n]*$")
  if now - p.t0 > 300 then return "error", "Python ne répond pas depuis 5 min. Commande :\n" .. p.cmd .. "\n" .. log end
  return "wait"
end

-- Attaques d'une piste, en temps projet, triées ; marque les attaques situées sur un raccord existant
-- (début d'un item qui chevauche le précédent : trace d'un calage antérieur).
function R.track_onsets(t, ex, res)
  local list = {}
  local joins = {}
  for k = 2, #t.items do
    local a, b = t.items[k - 1], t.items[k]
    if b.pos < a.pos + a.len + 1e-6 then joins[#joins + 1] = b.pos end
  end
  for _, o in ipairs(res.onsets or {}) do
    local x = { t = ex.r0 + o.t, t_start = ex.r0 + o.t_start, conf = o.conf, sure = o.sure, amb = o.amb,
                contrast = o.contrast, cuts = {} }
    for _, c in ipairs(o.cuts or {}) do x.cuts[#x.cuts + 1] = ex.r0 + c end
    -- saut de phase du fondu d'un raccord antérieur : revu comme une attaque à ±3 ms du raccord ; la vraie
    -- attaque est 5 à 17 ms plus loin et n'est pas concernée
    for _, j in ipairs(joins) do
      if math.abs(x.t - j) < R.JOIN_TOL then x.join = true end
    end
    list[#list + 1] = x
  end
  table.sort(list, function(a, b) return a.t < b.t end)
  return list
end

-- ------------------------------------------------------------------ sauvegardes
-- Copie datée du .rpp, une fois par session, avant la première application. Renvoie (ok, message).
function R.backup_rpp()
  local _, path = reaper.EnumProjects(-1, "")
  if not path or path == "" then
    local r = reaper.ShowMessageBox("Le projet n'a jamais été enregistré : aucune copie du .rpp ne peut être faite.\n\n" ..
      "Continuer quand même (annulation Reaper et pistes de copie restent disponibles) ?", "AutoEdit", 4)
    return r == 6, "pas de copie du .rpp (projet jamais enregistré)"
  end
  if reaper.IsProjectDirty(0) ~= 0 then
    local r = reaper.ShowMessageBox("Le projet a des modifications non enregistrées.\n\n" ..
      "Oui : enregistrer maintenant, puis faire la copie datée du .rpp.\n" ..
      "Non : copier la dernière version enregistrée (sans ces modifications).\nAnnuler : ne rien appliquer.",
      "AutoEdit", 3)
    if r == 2 then return false, "annulé" end
    if r == 6 then reaper.Main_SaveProject(0, false) end
  end
  local data = R.read_file(path)
  if not data then return false, "lecture impossible : " .. path end
  local base, ext = path:match("^(.*)(%.[Rr][Pp][Pp])$")
  base, ext = base or path, ext or ".rpp"
  local dst = base .. "_avant-AutoEdit_" .. os.date("%Y%m%d-%H%M%S") .. ext
  local f = io.open(dst, "wb")
  if not f then return false, "écriture impossible : " .. dst end
  f:write(data)
  f:close()
  return true, dst
end

local function strip_guids(chunk)
  return (chunk:gsub("\n%s*IGUID [^\n]*", ""):gsub("\n%s*GUID [^\n]*", ""):gsub("\n%s*POOLEDEVTS [^\n]*", ""))
end

-- Piste muette « AutoEdit original : nom » juste au-dessus de la piste (même dossier), avec une copie des items.
-- Une seule par piste et par session : les items déjà copiés ne le sont pas deux fois.
function R.copy_originals(t, session)
  session.copies = session.copies or {}
  local c = session.copies[t.guid]
  local copy_tr = c and reaper.ValidatePtr(c.tr, "MediaTrack*") and c.tr
  if not copy_tr then
    local idx = math.floor(reaper.GetMediaTrackInfo_Value(t.tr, "IP_TRACKNUMBER")) - 1
    reaper.InsertTrackAtIndex(idx, false)
    copy_tr = reaper.GetTrack(0, idx)
    reaper.GetSetMediaTrackInfo_String(copy_tr, "P_NAME", "AutoEdit original : " .. t.name, true)
    reaper.SetMediaTrackInfo_Value(copy_tr, "B_MUTE", 1)
    reaper.SetMediaTrackInfo_Value(copy_tr, "I_CUSTOMCOLOR", reaper.ColorToNative(150, 150, 150) | 0x1000000)
    c = { tr = copy_tr, done = {} }
    session.copies[t.guid] = c
  end
  for _, x in ipairs(t.items) do
    if not c.done[x.guid] then
      local _, ch = reaper.GetItemStateChunk(x.it, "", false)
      local nit = reaper.AddMediaItemToTrack(copy_tr)
      reaper.SetItemStateChunk(nit, strip_guids(ch), false)
      c.done[x.guid] = true
    end
  end
end

-- ------------------------------------------------------------------ application
-- Applique le plan d'un item : coupes, déplacements, fondus. Renvoie la liste des items résultants.
local function apply_item(x, plan, opts)
  local it = x.it
  local geo = core.segment_geometry({ pos = x.pos, len = x.len }, plan.segs, opts)
  if #geo <= 1 and math.abs(geo[1].d) < 1e-9 then return { it } end
  -- décalages de départ d'origine de chaque take, fondus extérieurs d'origine
  local takes = {}
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    takes[k] = tk and reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") or 0
  end
  local fin = reaper.GetMediaItemInfo_Value(it, "D_FADEINLEN")
  local fin_auto = reaper.GetMediaItemInfo_Value(it, "D_FADEINLEN_AUTO")
  local fout = reaper.GetMediaItemInfo_Value(it, "D_FADEOUTLEN")
  local fout_auto = reaper.GetMediaItemInfo_Value(it, "D_FADEOUTLEN_AUTO")
  -- coupes de droite à gauche : l'item d'origine reste le segment de gauche
  local parts = {}
  for j = #plan.segs, 2, -1 do
    local right = reaper.SplitMediaItem(it, plan.segs[j].c)
    if not right then error(string.format("coupe impossible à %.4f s", plan.segs[j].c)) end
    parts[j] = right
  end
  parts[1] = it
  -- géométrie imposée explicitement (indépendante des préférences de coupe de Reaper)
  for j, g in ipairs(geo) do
    local p = parts[j]
    reaper.SetMediaItemInfo_Value(p, "D_POSITION", g.pos)
    reaper.SetMediaItemInfo_Value(p, "D_LENGTH", g.len)
    for k = 0, reaper.CountTakes(p) - 1 do
      local tk = reaper.GetTake(p, k)
      if tk then reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", (takes[k] or 0) + g.offs) end
    end
    if g.fadein then
      reaper.SetMediaItemInfo_Value(p, "D_FADEINLEN", g.fadein)
      reaper.SetMediaItemInfo_Value(p, "D_FADEINLEN_AUTO", -1)
      reaper.SetMediaItemInfo_Value(p, "C_FADEINSHAPE", 0)
    else
      reaper.SetMediaItemInfo_Value(p, "D_FADEINLEN", fin)
      reaper.SetMediaItemInfo_Value(p, "D_FADEINLEN_AUTO", fin_auto)
    end
    if g.fadeout then
      reaper.SetMediaItemInfo_Value(p, "D_FADEOUTLEN", g.fadeout)
      reaper.SetMediaItemInfo_Value(p, "D_FADEOUTLEN_AUTO", -1)
      reaper.SetMediaItemInfo_Value(p, "C_FADEOUTSHAPE", 0)
    else
      reaper.SetMediaItemInfo_Value(p, "D_FADEOUTLEN", fout)
      reaper.SetMediaItemInfo_Value(p, "D_FADEOUTLEN_AUTO", fout_auto)
    end
  end
  return parts
end

-- Applique les plans de toutes les pistes. plans : { { t = piste scannée, items = { { x = item, plan } ... } } }
-- Renvoie une entrée d'historique (pour le retour arrière) et des compteurs.
function R.apply(plans, opts, session)
  local entry = { tracks = {}, time = os.date("%H:%M:%S") }
  local n_cuts, n_items = 0, 0
  reaper.Undo_BeginBlock2(0)
  reaper.PreventUIRefresh(1)
  local ok, err = pcall(function()
    for _, tp in ipairs(plans) do
      R.copy_originals(tp.t, session)
      local te = { guid = tp.t.guid, originals = {}, results = {} }
      for _, ip in ipairs(tp.items) do
        if #ip.plan.segs > 1 then
          local _, ch = reaper.GetItemStateChunk(ip.x.it, "", false)
          te.originals[#te.originals + 1] = ch
          local parts = apply_item(ip.x, ip.plan, opts)
          for _, p in ipairs(parts) do te.results[#te.results + 1] = guid_of_item(p) end
          n_cuts = n_cuts + #ip.plan.segs - 1
          n_items = n_items + 1
        end
      end
      entry.tracks[#entry.tracks + 1] = te
    end
  end)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(0, "AutoEdit : calage sur la grille", -1)
  if not ok then error(err, 0) end
  return entry, n_cuts, n_items
end

local function track_by_guid(g)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(tr) == g then return tr end
  end
end

-- Retour à l'état d'avant une application : supprime les segments créés, recrée les items d'origine.
function R.revert(entry)
  local missing = 0
  reaper.Undo_BeginBlock2(0)
  reaper.PreventUIRefresh(1)
  local ok, err = pcall(function()
    for _, te in ipairs(entry.tracks) do
      local tr = track_by_guid(te.guid)
      if not tr then
        missing = missing + 1
      else
        local want = {}
        for _, g in ipairs(te.results) do want[g] = true end
        for i = reaper.CountTrackMediaItems(tr) - 1, 0, -1 do
          local it = reaper.GetTrackMediaItem(tr, i)
          if want[guid_of_item(it)] then reaper.DeleteTrackMediaItem(tr, it) end
        end
        for _, ch in ipairs(te.originals) do
          local it = reaper.AddMediaItemToTrack(tr)
          reaper.SetItemStateChunk(it, ch, false)
        end
      end
    end
  end)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(0, "AutoEdit : retour à l'état d'avant", -1)
  if not ok then error(err, 0) end
  return missing
end

return R
