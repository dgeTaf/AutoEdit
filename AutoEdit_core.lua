-- AutoEdit_core.lua : logique pure (aucun appel Reaper qui modifie le projet), testable hors de Reaper.
--   grille de tempo (lignes par mesure et par subdivision), choix automatique de la subdivision par mesure,
--   propositions de déplacement, plan de coupe d'un item (points de coupe sûrs, notes bloquées).
-- Les temps sont en secondes « projet ». Voir docs/ALGORITHME.md.

local M = {}

-- subdivisions, de la plus grossière à la plus fine. step : en noires (QN) ; "beat" dépend de la signature.
M.LEVELS = {
  { key = "beat", label = "Temps" },
  { key = "e8", label = "Croches", step = 1 / 2 },
  { key = "t8", label = "Triolets de croche", step = 1 / 3 },
  { key = "e16", label = "Doubles croches", step = 1 / 4 },
  { key = "t16", label = "Triolets de double", step = 1 / 6 },
}
M.LEVEL_INDEX = {}
for i, l in ipairs(M.LEVELS) do M.LEVEL_INDEX[l.key] = i end

M.DEFAULTS = {
  strength = 1.0,          -- force 0..1
  max_ms = 30,             -- décalage maximal accepté (écart à la ligne), ms
  win_frac = 0.35,         -- fenêtre d'appariement : fraction de l'écart entre lignes
  auto_ratio = 0.75,       -- choix auto : la plus grossière où au moins 75 % des attaques tombent dans la fenêtre
  min_excess = 0.20,       -- ... et au moins 20 points de plus que la part attendue au hasard
  min_move_ms = 0.3,       -- en dessous : pas de coupe
  move_doubtful = false,   -- déplacer aussi les attaques douteuses
  xf_ms = 3,               -- fondu enchaîné aux raccords
  margin_ms = 1.0,         -- marge entre la fin du segment révélé / du fondu et le début de l'attaque
  keep_ms = 15,            -- durée minimale gardée après l'attaque précédente
  levels = { beat = true, e8 = true, t8 = true, e16 = true, t16 = true },
}

-- durée d'un temps en noires : 6/8, 9/8, 12/8 -> noire pointée ; x/8 autres -> croche ; x/4 -> noire ; x/2 -> blanche
function M.beat_qn(num, den)
  local unit = 4 / den
  if den >= 8 and num % 3 == 0 and num > 3 then return 3 * unit end
  return unit
end

local function level_step(key, num, den)
  if key == "beat" then return M.beat_qn(num, den) end
  return M.LEVELS[M.LEVEL_INDEX[key]].step
end

-- Grille entre t0 et t1. tm : interface sur la carte de tempo (voir AutoEdit_reaper.lua) :
--   tm.measure_at(t) -> index de mesure (0 = première) ; tm.info(m) -> t_start, qn0, qn1, num, den ;
--   tm.qn_to_time(qn) -> s.
-- Renvoie une liste de mesures { idx, t0, t1, num, den, lines = { [key] = { temps... } }, spacing = { [key] = s } }.
function M.build_grid(t0, t1, tm)
  local out = {}
  local m = tm.measure_at(t0)
  for _ = 1, 10000 do
    local ts, qn0, qn1, num, den = tm.info(m)
    if ts > t1 then break end
    local meas = { idx = m, t0 = ts, t1 = tm.qn_to_time(qn1), num = num, den = den, lines = {}, spacing = {} }
    for _, l in ipairs(M.LEVELS) do
      local step = level_step(l.key, num, den)
      local lines = {}
      local n = math.floor((qn1 - qn0) / step + 1e-6)
      for k = 0, n do                       -- inclut la ligne de fin (= premier temps de la mesure suivante)
        local q = qn0 + k * step
        if q > qn1 + 1e-6 then break end
        lines[#lines + 1] = tm.qn_to_time(q)
      end
      if lines[#lines] and math.abs((qn0 + n * step) - qn1) > 1e-6 then
        lines[#lines + 1] = tm.qn_to_time(qn1)   -- mesure incomplète pour ce pas : la barre suivante reste une ligne
      end
      meas.lines[l.key] = lines
      meas.spacing[l.key] = tm.qn_to_time(qn0 + step) - ts
    end
    out[#out + 1] = meas
    m = m + 1
  end
  return out
end

local function measure_of(grid, t)
  for i, ms in ipairs(grid) do
    if t >= ms.t0 - 1e-9 and t < ms.t1 then return i end
  end
  return nil
end
M.measure_of = measure_of

local function nearest(lines, t)
  local best, bd = nil, math.huge
  for _, l in ipairs(lines) do
    local d = math.abs(t - l)
    if d < bd then best, bd = l, d end
  end
  return best
end

-- fenêtre d'appariement (s) d'une subdivision dans une mesure
function M.window(meas, key, opts)
  return math.min(opts.win_frac * meas.spacing[key], opts.max_ms / 1000)
end

-- Pour chaque attaque : mesure et, par subdivision, ligne la plus proche et écart (s, positif = en retard).
function M.match(onsets, grid)
  for _, o in ipairs(onsets) do
    local mi = measure_of(grid, o.t)
    o.meas = mi
    o.cand = {}
    if mi then
      for _, l in ipairs(M.LEVELS) do
        local line = nearest(grid[mi].lines[l.key], o.t)
        o.cand[l.key] = { line = line, off = o.t - line }
      end
    end
  end
end

-- Choix automatique par mesure : la subdivision active la plus grossière où au moins auto_ratio des attaques
-- sûres tombent dans la fenêtre ET nettement plus que le hasard (part attendue au hasard = 2 x fenêtre / écart :
-- avec une fenêtre de 35 % de l'écart, une grille fine attrape 70 % de notes jouées n'importe où).
-- Sinon : mesure IRRÉGULIÈRE (meilleur excès sur le hasard affiché, notes non déplacées sauf choix forcé).
-- Renvoie, par mesure, { key, ratio, n, irregular }.
function M.choose_levels(onsets, grid, opts)
  local per = {}
  for i = 1, #grid do per[i] = {} end
  for _, o in ipairs(onsets) do
    if o.meas and not o.join and (o.sure or opts.move_doubtful) then table.insert(per[o.meas], o) end
  end
  local min_excess = opts.min_excess or 0.2
  local res = {}
  for i, ms in ipairs(grid) do
    local list = per[i]
    local choice = { key = nil, ratio = 0, n = #list, irregular = false }
    local best, best_ex = nil, -math.huge
    if #list > 0 then
      for _, l in ipairs(M.LEVELS) do
        if opts.levels[l.key] then
          local w, k = M.window(ms, l.key, opts), 0
          for _, o in ipairs(list) do
            if math.abs(o.cand[l.key].off) <= w then k = k + 1 end
          end
          local r = k / #list
          local chance = math.min(1, 2 * w / ms.spacing[l.key])
          local ex = r - chance
          if r >= opts.auto_ratio and ex >= min_excess then
            choice.key, choice.ratio = l.key, r
            break
          end
          if ex > best_ex + 1e-9 then best, best_ex = { key = l.key, ratio = r }, ex end
        end
      end
      if not choice.key and best then
        choice.key, choice.ratio, choice.irregular = best.key, best.ratio, true
      end
    end
    res[i] = choice
  end
  return res
end

-- Propositions. levels[i] : subdivision de la mesure i (choix auto ou forcé). topt : réglages de la piste
-- { strength (0..1), target_ms (décalage voulu, + = en arrière), enabled = { [index] = false } }.
-- Chaque attaque reçoit : line (s), off_ms (écart actuel à la ligne), shift (s, déplacement proposé),
-- status : "move" | "small" | "offgrid" | "irregular" | "doubtful" | "outside" | "join" (sur un raccord)
--          | "user" (décochée).
function M.proposals(onsets, grid, levels, topt, opts, sel0, sel1)
  local strength = topt.strength or opts.strength
  local target = (topt.target_ms or 0) / 1000
  for i, o in ipairs(onsets) do
    o.shift, o.line, o.off_ms, o.level = 0, nil, nil, nil
    if not o.meas or o.t < sel0 or o.t > sel1 then
      o.status = "outside"
    elseif o.join then
      o.status = "join"          -- artefact d'un raccord existant : ni déplacé ni compté
    else
      local key = levels[o.meas] and levels[o.meas].key
      if not key then
        o.status = "offgrid"
      else
        local c = o.cand[key]
        o.level, o.line, o.off_ms = key, c.line, (c.off - target) * 1000
        local w = M.window(grid[o.meas], key, opts)
        if levels[o.meas].irregular and not levels[o.meas].forced then
          o.status = "irregular"   -- mesure irrégulière : rien n'est déplacé sans choix forcé
        elseif math.abs(c.off) > w then
          o.status = "offgrid"
        elseif not o.sure and not opts.move_doubtful then
          o.status = "doubtful"
        else
          o.shift = -(c.off - target) * strength
          o.status = math.abs(o.shift) * 1000 < opts.min_move_ms and "small" or "move"
          if o.status == "small" then o.shift = 0 end
        end
        if topt.enabled and topt.enabled[i] == false and o.status == "move" then
          o.status, o.shift = "user", 0
        end
      end
    end
  end
end

-- Plan de coupe d'un item. onsets : attaques de l'item (triées), avec t, t_start (s, projet), shift (s) et
-- cuts (liste de temps de coupe candidats, s, projet, triés : creux d'énergie / passages par zéro avant l'attaque).
-- item : { pos, len }. Renvoie { segs = { { c = temps de coupe (ou pos de l'item), d = déplacement } ... },
-- blocked = { index d'attaque = raison } }.
--
-- Contraintes d'une coupe c avant l'attaque i (D = d_i - d_{i-1}) :
--   le segment précédent est étendu ou rogné pour finir à c + d_i + xf (fondu) : il lit la source jusqu'à
--   c + D + xf, qui doit rester avant le début d'attaque (t_start - marge) -> sinon l'attaque serait doublée ;
--   le fondu d'entrée du segment i lit [c, c + xf], aussi avant l'attaque :
--       c <= t_start - marge - xf - max(D, 0)
--   le segment précédent garde au moins keep_ms après sa propre attaque, même rogné :
--       c >= t_prev + keep + max(-D, 0) - xf ... borné aussi par le début de l'item.
-- Sans coupe possible, la note est BLOQUÉE : elle suit le segment précédent (même déplacement).
function M.plan_item(item, onsets, opts)
  local xf, margin, keep = opts.xf_ms / 1000, opts.margin_ms / 1000, opts.keep_ms / 1000
  local segs = { { c = item.pos, d = 0 } }
  local blocked = {}
  local prev_t = nil
  local cur_d = 0
  for i, o in ipairs(onsets) do
    local d = o.shift or 0
    if math.abs(d - cur_d) > 1e-5 then
      local D = d - cur_d
      local cmax = o.t_start - margin - xf - math.max(D, 0)
      local cmin = (prev_t and (prev_t + keep + math.max(-D, 0) - xf)) or -math.huge
      cmin = math.max(cmin, segs[#segs].c + 2 * xf + 0.001)     -- segment précédent assez long pour ses fondus
      local c = nil
      if cmax >= cmin then
        -- creux d'énergie le plus tardif dans [cmin, cmax], sinon cmax
        c = cmax
        if o.cuts then
          for k = #o.cuts, 1, -1 do
            local cc = o.cuts[k]
            if cc <= cmax and cc >= cmin then c = cc break end
          end
        end
      end
      if c then
        segs[#segs + 1] = { c = c, d = d, onset = i }
        cur_d = d
      else
        blocked[i] = cmax < (prev_t or item.pos) and "trop proche de la note précédente" or "pas de point de coupe sûr"
        o.shift_applied = cur_d
      end
    end
    if not blocked[i] then o.shift_applied = cur_d end
    prev_t = o.t
  end
  return { segs = segs, blocked = blocked }
end

-- Géométrie des segments après application (pour l'application et la simulation de test).
-- Renvoie une liste { pos, len, offs (décalage dans l'item d'origine, s), fadein, fadeout }.
-- La fin de l'item reste à sa place (le dernier segment est rallongé ou rogné).
function M.segment_geometry(item, segs, opts)
  local xf = opts.xf_ms / 1000
  local out = {}
  local item_end = item.pos + item.len
  for j, s in ipairs(segs) do
    local pos = s.c + s.d
    local nxt = segs[j + 1]
    local e = nxt and (nxt.c + nxt.d + xf) or item_end
    out[j] = { pos = pos, len = e - pos, offs = s.c - item.pos, fadein = j > 1 and xf or nil,
               fadeout = nxt and xf or nil, d = s.d }
  end
  return out
end

-- Position lisible « mesure.temps.centièmes » à partir d'un temps (tm.time_to_beats -> beat, measure, ...).
function M.fmt_pos(tm, t)
  local beat, meas = tm.time_to_beats(t)
  local b = math.floor(beat + 1e-6)
  return string.format("%d.%d.%02d", meas + 1, b + 1, math.floor((beat - b) * 100 + 0.5) % 100)
end

return M
