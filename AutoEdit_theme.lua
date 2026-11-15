-- AutoEdit_theme.lua : thème clair « gris perle » repris de MixLike (RefMatch_theme.lua), éléments dessinés à la main.
-- Compatible ReaImGui 0.9 et 0.10 (les polices ont changé d'API entre les deux).

local T = {}
local im = reaper

-- couleurs 0xRRGGBBAA
T.C = {
  bg = 0xECEEF1FF, card = 0xFFFFFFFF, border = 0xDDE0E5FF, line = 0xECEEF1FF,
  text = 0x2B2F36FF, title = 0x1D2128FF, muted = 0x7A808AFF, faint = 0x9AA0A9FF,
  accent = 0x2F6FDEFF, accent_hi = 0x4A84E6FF, accent_lo = 0x245CC0FF,
  field = 0xF4F5F7FF, field_hi = 0xE9ECF0FF, btn = 0xF4F5F7FF, btn_hi = 0xE6E9EEFF,
  mix = 0xE07B1FFF, ref = 0x2F6FDEFF,
  green = 0x16A07AFF, purple = 0x7C5CE0FF, red = 0xD9443CFF, orange = 0xE07B1FFF,
  yellow = 0xC99A12FF, blue = 0x2F6FDEFF, gray = 0x7A808AFF,
}
local C = T.C

function T.alpha(col, a) return (col & 0xFFFFFF00) | math.floor(a * 255 + 0.5) end

-- ------------------------------------------------------------------ polices
local fonts, new_font_api = {}, false
local SIZES = { body = 14, small = 12, title = 17, big = 21 }

function T.init(ctx)
  local ver = select(3, im.ImGui_GetVersion()) or "0.9"
  local maj, min = ver:match("^(%d+)%.(%d+)")
  new_font_api = (tonumber(maj) or 0) > 0 or (tonumber(min) or 0) >= 10
  local family = (reaper.GetOS() or ""):match("^Win") and "Segoe UI" or "sans-serif"
  local bold = im.ImGui_FontFlags_Bold and im.ImGui_FontFlags_Bold() or 0
  local function make(fam, size, flags)
    if new_font_api then return im.ImGui_CreateFont(fam, flags) end
    return im.ImGui_CreateFont(fam, size, flags)
  end
  for k, size in pairs(SIZES) do
    local flags = (k == "title" or k == "big") and bold or 0
    local ok, f = pcall(make, family, size, flags)
    if not ok or not f then ok, f = pcall(make, "sans-serif", size, flags) end
    if ok and f then
      im.ImGui_Attach(ctx, f)
      fonts[k] = f
    end
  end
end

function T.push_font(ctx, kind)
  local f = fonts[kind]
  if not f then return false end
  if new_font_api then im.ImGui_PushFont(ctx, f, SIZES[kind]) else im.ImGui_PushFont(ctx, f) end
  return true
end

function T.pop_font(ctx, pushed)
  if pushed then im.ImGui_PopFont(ctx) end
end

function T.text(ctx, kind, col, s)
  local p = T.push_font(ctx, kind)
  im.ImGui_TextColored(ctx, col or C.text, s)
  T.pop_font(ctx, p)
end

-- ------------------------------------------------------------------ style global
local COLS = {
  WindowBg = C.bg, ChildBg = 0, PopupBg = C.card, Border = C.border, Text = C.text, TextDisabled = C.faint,
  FrameBg = C.field, FrameBgHovered = C.field_hi, FrameBgActive = C.field_hi,
  TitleBg = C.bg, TitleBgActive = 0xDCDFE4FF, TitleBgCollapsed = C.bg,
  Button = C.btn, ButtonHovered = C.btn_hi, ButtonActive = 0xDADEE4FF,
  Header = 0xE6ECF8FF, HeaderHovered = 0xDCE6F7FF, HeaderActive = 0xD0DDF5FF,
  Tab = 0x00000000, TabHovered = 0xFFFFFFB0, TabActive = C.card, TabSelected = C.card,
  TabUnfocusedActive = C.card, TabDimmedSelected = C.card,
  TableHeaderBg = C.bg, TableBorderLight = C.line, TableBorderStrong = C.border,
  TableRowBg = 0, TableRowBgAlt = 0xF7F8FAFF,
  CheckMark = C.accent, SliderGrab = C.accent, SliderGrabActive = C.accent_lo,
  ScrollbarBg = 0, ScrollbarGrab = 0xC9CDD4FF, ScrollbarGrabHovered = 0xB5BAC2FF,
  Separator = C.border, PlotHistogram = C.accent, TextSelectedBg = 0x2F6FDE40,
}
local VARS = {
  WindowPadding = { 16, 14 }, FramePadding = { 10, 6 }, ItemSpacing = { 8, 8 }, CellPadding = { 8, 6 },
  FrameRounding = 6, ChildRounding = 10, PopupRounding = 8, GrabRounding = 6, TabRounding = 6,
  ScrollbarRounding = 6, WindowRounding = 6, ChildBorderSize = 1, FrameBorderSize = 0,
}

function T.push(ctx)
  local n_col, n_var = 0, 0
  for name, col in pairs(COLS) do
    local f = im["ImGui_Col_" .. name]
    if f then
      im.ImGui_PushStyleColor(ctx, f(), col)
      n_col = n_col + 1
    end
  end
  for name, v in pairs(VARS) do
    local f = im["ImGui_StyleVar_" .. name]
    if f then
      if type(v) == "table" then im.ImGui_PushStyleVar(ctx, f(), v[1], v[2]) else im.ImGui_PushStyleVar(ctx, f(), v) end
      n_var = n_var + 1
    end
  end
  local pf = T.push_font(ctx, "body")
  return { n_col, n_var, pf }
end

function T.pop(ctx, st)
  T.pop_font(ctx, st[3])
  im.ImGui_PopStyleVar(ctx, st[2])
  im.ImGui_PopStyleColor(ctx, st[1])
end

-- ------------------------------------------------------------------ éléments
-- Carte blanche bordée. Ce n'est PAS une sous-fenêtre ImGui (BeginChild) : avec ReaImGui 0.10, des cartes
-- en sous-fenêtres faisaient planter le script au défilement (« EndChild : child_window->Flags & ChildWindow »).
-- C'est un groupe : le fond est dessiné à la hauteur mesurée au passage précédent, puis le contenu par-dessus.
-- h = 0 : hauteur automatique ; h > 0 : hauteur fixe.
local PADX, PADY = 12, 10
local card_h, cards = {}, {}

function T.begin_card(ctx, id, w, h)
  local x, y = im.ImGui_GetCursorScreenPos(ctx)
  local lx = im.ImGui_GetCursorPosX(ctx)
  local aw = im.ImGui_GetContentRegionAvail(ctx)
  w = (w and w > 0) and w or aw
  local fixed = h and h > 0
  local hh = fixed and h or (card_h[id] or 2 * PADY + 20)
  local dl = im.ImGui_GetWindowDrawList(ctx)
  im.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + hh, C.card, 10)
  im.ImGui_DrawList_AddRect(dl, x, y, x + w, y + hh, C.border, 10, 0, 1)
  local s = { id = id, x = x, y = y, w = w, h = hh, fixed = fixed, lx = lx + PADX, cw = w - 2 * PADX }
  cards[#cards + 1] = s
  im.ImGui_SetCursorScreenPos(ctx, x + PADX, y + PADY)
  if fixed then im.ImGui_PushClipRect(ctx, x, y, x + w, y + hh, true) end
  im.ImGui_PushTextWrapPos(ctx, s.lx + s.cw)
  im.ImGui_BeginGroup(ctx)
  return true
end

function T.end_card(ctx)
  local s = table.remove(cards)
  im.ImGui_EndGroup(ctx)
  im.ImGui_PopTextWrapPos(ctx)
  if s.fixed then im.ImGui_PopClipRect(ctx) end
  local _, maxy = im.ImGui_GetItemRectMax(ctx)
  local hh = s.fixed and s.h or math.max(2 * PADY, maxy - s.y + PADY)
  card_h[s.id] = hh
  im.ImGui_SetCursorScreenPos(ctx, s.x, s.y + hh)
  im.ImGui_Dummy(ctx, s.w, 0)
end

-- largeur utile de la carte en cours, et position (locale à la fenêtre) pour aligner un élément à droite
function T.card_w()
  local s = cards[#cards]
  return s and s.cw or 0
end

-- pour SameLine(ctx, x) : dans un groupe, x se compte depuis le début du groupe (le bord gauche du contenu de la carte)
function T.card_right(width)
  local s = cards[#cards]
  return s and math.max(1, s.cw - width) or 0
end

-- trait de séparation à la largeur de la carte
function T.sep(ctx)
  local s = cards[#cards]
  local x, y = im.ImGui_GetCursorScreenPos(ctx)
  local w = s and s.cw or im.ImGui_GetContentRegionAvail(ctx)
  im.ImGui_DrawList_AddLine(im.ImGui_GetWindowDrawList(ctx), x, y + 3, x + w, y + 3, C.line, 1)
  im.ImGui_Dummy(ctx, w, 6)
end

-- petit titre de section en capitales grises
function T.label(ctx, s)
  T.text(ctx, "small", C.muted, s)
end

-- pastille colorée (texte sur fond teinté)
function T.chip(ctx, s, col)
  local p = T.push_font(ctx, "small")
  local tw, th = im.ImGui_CalcTextSize(ctx, s)
  local x, y = im.ImGui_GetCursorScreenPos(ctx)
  local dl = im.ImGui_GetWindowDrawList(ctx)
  local w, h = tw + 14, th + 4
  im.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.alpha(col, 0.13), h / 2)
  im.ImGui_DrawList_AddText(dl, x + 7, y + 2, col, s)
  im.ImGui_Dummy(ctx, w, h)
  T.pop_font(ctx, p)
end

-- barre verticale de couleur (couleur de piste)
function T.swatch(ctx, col, h)
  local x, y = im.ImGui_GetCursorScreenPos(ctx)
  local dl = im.ImGui_GetWindowDrawList(ctx)
  im.ImGui_DrawList_AddRectFilled(dl, x, y + 1, x + 4, y + (h or 18), col or C.faint, 2)
  im.ImGui_Dummy(ctx, 6, h or 18)
end

-- mini-vumètre horizontal (frac 0..1)
function T.meter(ctx, frac, col, w)
  w = w or 60
  local x, y = im.ImGui_GetCursorScreenPos(ctx)
  local dl = im.ImGui_GetWindowDrawList(ctx)
  local yy = y + 7
  im.ImGui_DrawList_AddRectFilled(dl, x, yy, x + w, yy + 6, C.line, 3)
  im.ImGui_DrawList_AddRectFilled(dl, x, yy, x + math.max(4, w * math.max(0, math.min(1, frac))), yy + 6, col, 3)
  im.ImGui_Dummy(ctx, w, 20)
end

-- bouton principal (bleu plein)
function T.accent_button(ctx, s, w, h)
  im.ImGui_PushStyleColor(ctx, im.ImGui_Col_Button(), C.accent)
  im.ImGui_PushStyleColor(ctx, im.ImGui_Col_ButtonHovered(), C.accent_hi)
  im.ImGui_PushStyleColor(ctx, im.ImGui_Col_ButtonActive(), C.accent_lo)
  im.ImGui_PushStyleColor(ctx, im.ImGui_Col_Text(), 0xFFFFFFFF)
  local r = im.ImGui_Button(ctx, s, w or 0, h or 0)
  im.ImGui_PopStyleColor(ctx, 4)
  return r
end

-- bouton discret, éventuellement coloré
function T.button(ctx, s, col, w, h)
  if col then
    im.ImGui_PushStyleColor(ctx, im.ImGui_Col_Button(), T.alpha(col, 0.12))
    im.ImGui_PushStyleColor(ctx, im.ImGui_Col_ButtonHovered(), T.alpha(col, 0.22))
    im.ImGui_PushStyleColor(ctx, im.ImGui_Col_ButtonActive(), T.alpha(col, 0.32))
    im.ImGui_PushStyleColor(ctx, im.ImGui_Col_Text(), col)
  end
  local r = im.ImGui_Button(ctx, s, w or 0, h or 0)
  if col then im.ImGui_PopStyleColor(ctx, 4) end
  return r
end

-- jauge circulaire façon potard : position du mix (arc coloré + aiguille) et repère de la référence
-- (petit triangle sombre posé sur l'extérieur de l'arc, tout reste dans le carré size × size)
function T.gauge(ctx, size, f_mix, f_ref, col)
  local x, y = im.ImGui_GetCursorScreenPos(ctx)
  local dl = im.ImGui_GetWindowDrawList(ctx)
  local r = size * 0.34
  local cx, cy = x + size / 2, y + size / 2 + 2
  local a0, span = 0.75 * math.pi, 1.5 * math.pi
  local function clamp(v) return math.max(0, math.min(1, v)) end
  f_mix, f_ref = clamp(f_mix), clamp(f_ref)
  im.ImGui_DrawList_PathArcTo(dl, cx, cy, r, a0, a0 + span, 40)
  im.ImGui_DrawList_PathStroke(dl, 0xE6E8ECFF, 0, 5)
  if f_mix > 0.01 then
    im.ImGui_DrawList_PathArcTo(dl, cx, cy, r, a0, a0 + span * f_mix, 40)
    im.ImGui_DrawList_PathStroke(dl, col, 0, 5)
  end
  local ar = a0 + span * f_ref
  local ca, sa = math.cos(ar), math.sin(ar)
  local tip, base = r + 3, r + 9          -- pointe vers l'arc
  local px, py = -sa * 3.5, ca * 3.5     -- demi-largeur, perpendiculaire au rayon
  im.ImGui_DrawList_AddTriangleFilled(dl, cx + tip * ca, cy + tip * sa,
    cx + base * ca + px, cy + base * sa + py, cx + base * ca - px, cy + base * sa - py, C.title)
  local am = a0 + span * f_mix
  im.ImGui_DrawList_AddCircleFilled(dl, cx, cy, r * 0.62, C.field)
  im.ImGui_DrawList_AddCircle(dl, cx, cy, r * 0.62, C.border, 0, 1)
  im.ImGui_DrawList_AddLine(dl, cx, cy, cx + r * 0.48 * math.cos(am), cy + r * 0.48 * math.sin(am), C.text, 2)
  im.ImGui_Dummy(ctx, size, size)
end

return T
