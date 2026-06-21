require "import"
import "cjson"
import "android.app.AlertDialog"
import "android.widget.*"
import "android.os.*"
import "android.view.*"
import "android.content.Context"
import "android.content.Intent"
import "android.content.DialogInterface"
import "android.graphics.Color"
import "android.graphics.Typeface"
import "android.graphics.drawable.GradientDrawable"
import "android.graphics.pdf.PdfDocument"
import "android.graphics.Canvas"
import "android.graphics.Paint"
import "java.io.File"
import "java.io.FileOutputStream"
import "java.io.BufferedReader"
import "java.io.InputStreamReader"
import "java.io.OutputStreamWriter"
import "android.text.InputType"
import "java.lang.System"
import "java.lang.Thread"
import "java.net.URL"
import "java.util.zip.ZipOutputStream"
import "java.util.zip.ZipEntry"
import "com.androlua.Http"
import "android.util.TypedValue"
import "android.media.ToneGenerator"
import "android.media.AudioManager"
import "android.text.Html"
import "android.net.Uri"
import "android.speech.tts.TextToSpeech"

local ctx = service or activity
local uiH = Handler(Looper.getMainLooper())
local File_CLASS = luajava.bindClass("java.io.File")
local Env_CLASS = luajava.bindClass("android.os.Environment")
local JavaString = luajava.bindClass("java.lang.String")

-- ==================== COLORS & STYLING ====================
local C = {
    bg       = Color.parseColor("#121212"),
    surface  = Color.parseColor("#1E1E1E"),
    primary  = Color.parseColor("#2196F3"),
    green    = Color.parseColor("#4CAF50"),
    danger   = Color.parseColor("#F44336"),
    warn     = Color.parseColor("#FF9800"),
    purple   = Color.parseColor("#9C27B0"),
    text     = Color.parseColor("#FFFFFF"),
    sub      = Color.parseColor("#B0B0B0"),
    divider  = Color.parseColor("#333333"),
}

local function dp(n)
    return math.floor(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, n, ctx.getResources().getDisplayMetrics()))
end

local function ui(fn) uiH.post(Runnable{ run = function() pcall(fn) end }) end
local function toast(msg) ui(function() Toast.makeText(ctx, tostring(msg), Toast.LENGTH_SHORT).show() end) end

local function clickEffect()
    pcall(function()
        local tg = ToneGenerator(AudioManager.STREAM_MUSIC, 70)
        tg.startTone(ToneGenerator.TONE_PROP_BEEP, 35)
        uiH.postDelayed(Runnable{ run = function() tg.release() end }, 50)
    end)
end

local function rounded(color, r, sw, sc)
    local d = GradientDrawable()
    d.setShape(GradientDrawable.RECTANGLE)
    d.setCornerRadius(dp(r or 8))
    d.setColor(color or C.surface)
    if sw and sc then d.setStroke(dp(sw), sc) end
    return d
end

local function tv(text, size, color, bold)
    local t = TextView(ctx)
    t.setText(tostring(text or ""))
    t.setTextSize(size or 14)
    t.setTextColor(color or C.text)
    if bold then t.setTypeface(Typeface.DEFAULT_BOLD) end
    return t
end

local function makeBtn(text, bg, fg)
    local b = Button(ctx)
    b.setText(text)
    b.setBackground(rounded(bg or C.surface, 8))
    b.setTextColor(fg or C.text)
    b.setTypeface(Typeface.DEFAULT_BOLD)
    b.setTextSize(14)
    b.setPadding(dp(10), dp(15), dp(10), dp(15))
    local p = LinearLayout.LayoutParams(-1, -2)
    p.setMargins(0, dp(5), 0, dp(5))
    b.setLayoutParams(p)
    return b
end

local function makeInput(hint, isMultiLine)
    local et = EditText(ctx)
    et.setHint(hint or "")
    et.setBackground(rounded(C.surface, 8, 1, C.divider))
    et.setTextColor(C.text)
    et.setHintTextColor(C.sub)
    et.setPadding(dp(15), dp(15), dp(15), dp(15))
    if isMultiLine then
        et.setGravity(Gravity.TOP | Gravity.LEFT)
        et.setMinLines(4)
    else
        et.setSingleLine(true)
    end
    local p = LinearLayout.LayoutParams(-1, -2)
    p.setMargins(0, dp(5), 0, dp(10))
    et.setLayoutParams(p)
    return et
end

-- ==================== BASIC STRING / MARKDOWN HELPERS ====================
local function mdToHtml(md)
    if not md then return "" end
    local s = tostring(md)
    s = s:gsub("%*%*(.-)%*%*", "<b>%1</b>")
    s = s:gsub("%*(.-)%*", "<i>%1</i>")
    s = s:gsub("### (.-)\n", "<h3>%1</h3>")
    s = s:gsub("## (.-)\n", "<h2>%1</h2>")
    s = s:gsub("# (.-)\n", "<h1>%1</h1>")
    s = s:gsub("\n%- (.-)", "<br>&#8226; %1")
    s = s:gsub("\n%* (.-)", "<br>&#8226; %1")
    s = s:gsub("\n", "<br>")
    return s
end

local function stripMd(md)
    if not md then return "" end
    local s = tostring(md)
    s = s:gsub("%*%*(.-)%*%*", "%1")
    s = s:gsub("%*(.-)%*", "%1")
    s = s:gsub("#+ ", "")
    return s
end

local function stripBoldMarkers(s)
    return tostring(s or ""):gsub("%*%*", "")
end

-- Strips ```code fences``` from AI replies so raw JSON / text can be parsed or exported cleanly
local function cleanCodeBlocks(content)
    local s = tostring(content or "")
    s = s:gsub("```%a*\n", "")
    s = s:gsub("```", "")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

local function escapeHtml(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    return s
end

local function escapeXml(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&apos;")
    return s
end

-- Splits one logical line of resume markdown into typed blocks (heading/bullet/paragraph/blank).
-- Shared by every real format builder below (HTML, RTF, PDF, DOCX, ODT) so they all agree
-- on what counts as a heading or a bullet.
local function parseMarkdownBlocks(md)
    local blocks = {}
    local text = tostring(md or "")
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == "" then
            table.insert(blocks, {type="blank"})
        elseif trimmed:match("^### ") then
            table.insert(blocks, {type="h3", text=trimmed:gsub("^### ", "")})
        elseif trimmed:match("^## ") then
            table.insert(blocks, {type="h2", text=trimmed:gsub("^## ", "")})
        elseif trimmed:match("^# ") then
            table.insert(blocks, {type="h1", text=trimmed:gsub("^# ", "")})
        elseif trimmed:match("^[%-%*] ") then
            table.insert(blocks, {type="bullet", text=trimmed:gsub("^[%-%*] ", "")})
        else
            table.insert(blocks, {type="para", text=trimmed})
        end
    end
    return blocks
end

-- Splits "some **bold** text" into ordered {text=, bold=} segments for rich renderers.
local function splitBoldSegments(text)
    text = tostring(text or "")
    local segments = {}
    local pos = 1
    while true do
        local s, e = text:find("%*%*.-%*%*", pos)
        if not s then
            if pos <= #text then table.insert(segments, {text=text:sub(pos), bold=false}) end
            break
        end
        if s > pos then table.insert(segments, {text=text:sub(pos, s - 1), bold=false}) end
        table.insert(segments, {text=text:sub(s + 2, e - 2), bold=true})
        pos = e + 1
    end
    if #segments == 0 then table.insert(segments, {text="", bold=false}) end
    return segments
end

-- ==================== REAL FORMAT BUILDERS ====================
-- These replace the old approach of asking the AI to directly hand-write RTF/XML/HTML/etc,
-- which was unreliable and produced files that did not open correctly. Now the AI only ever
-- writes one clean Markdown resume, and these functions deterministically convert that single
-- source of truth into the target file format, so every format builds correctly every time.

-- ----- HTML (full standalone document, used for .html export) -----
local function mdToFullHtml(md, titleText)
    local blocks = parseMarkdownBlocks(md)
    local body = {}
    local inList = false
    local function closeListIfOpen()
        if inList then table.insert(body, "</ul>"); inList = false end
    end
    local function renderInline(segs)
        local out = ""
        for _, sg in ipairs(segs) do
            local t = escapeHtml(sg.text)
            out = out .. (sg.bold and ("<b>" .. t .. "</b>") or t)
        end
        return out
    end
    for _, b in ipairs(blocks) do
        if b.type == "bullet" then
            if not inList then table.insert(body, "<ul>"); inList = true end
            table.insert(body, "<li>" .. renderInline(splitBoldSegments(b.text)) .. "</li>")
        else
            closeListIfOpen()
            if b.type == "h1" then
                table.insert(body, "<h1>" .. escapeHtml(b.text) .. "</h1>")
            elseif b.type == "h2" then
                table.insert(body, "<h2>" .. escapeHtml(b.text) .. "</h2>")
            elseif b.type == "h3" then
                table.insert(body, "<h3>" .. escapeHtml(b.text) .. "</h3>")
            elseif b.type == "para" then
                table.insert(body, "<p>" .. renderInline(splitBoldSegments(b.text)) .. "</p>")
            end
        end
    end
    closeListIfOpen()
    local html = table.concat(body, "\n")
    return "<!DOCTYPE html>\n<html><head><meta charset='UTF-8'><title>" .. escapeHtml(titleText or "Resume") .. "</title>" ..
        "<style>body{font-family:Arial,Helvetica,sans-serif;max-width:800px;margin:40px auto;color:#222;line-height:1.5;padding:0 20px}" ..
        "h1{color:#2196F3;border-bottom:2px solid #2196F3;padding-bottom:6px}h2{color:#1565C0;margin-top:24px}h3{color:#444}" ..
        "ul{padding-left:20px}li{margin-bottom:4px}p{margin:6px 0}</style></head><body>\n" .. html .. "\n</body></html>"
end

-- ----- RTF (used for .rtf export, and as a reliable stand-in for legacy .doc) -----
local function rtfEscapeChar(cp)
    if cp == 92 then return "\\\\"
    elseif cp == 123 then return "\\{"
    elseif cp == 125 then return "\\}"
    elseif cp < 128 then return string.char(cp)
    else
        local signedCp = cp
        if signedCp > 32767 then signedCp = signedCp - 65536 end
        return "\\u" .. tostring(signedCp) .. "?"
    end
end

local function rtfEscape(s)
    s = tostring(s or "")
    local out = {}
    local ok = pcall(function()
        for _, cp in utf8.codes(s) do
            table.insert(out, rtfEscapeChar(cp))
        end
    end)
    if not ok then
        out = {}
        for i = 1, #s do table.insert(out, rtfEscapeChar(s:byte(i))) end
    end
    return table.concat(out)
end

local function mdToRTF(md)
    local blocks = parseMarkdownBlocks(md)
    local body = {}
    local function renderInline(segs)
        local line = ""
        for _, sg in ipairs(segs) do
            if sg.bold then line = line .. "{\\b " .. rtfEscape(sg.text) .. "}"
            else line = line .. rtfEscape(sg.text) end
        end
        return line
    end
    for _, b in ipairs(blocks) do
        if b.type == "h1" then
            table.insert(body, "{\\b\\fs32 " .. rtfEscape(b.text) .. "}\\par\\par")
        elseif b.type == "h2" then
            table.insert(body, "{\\b\\fs26 " .. rtfEscape(b.text) .. "}\\par\\par")
        elseif b.type == "h3" then
            table.insert(body, "{\\b\\fs22 " .. rtfEscape(b.text) .. "}\\par")
        elseif b.type == "bullet" then
            table.insert(body, "\\bullet  " .. renderInline(splitBoldSegments(b.text)) .. "\\par")
        elseif b.type == "para" then
            table.insert(body, renderInline(splitBoldSegments(b.text)) .. "\\par")
        else
            table.insert(body, "\\par")
        end
    end
    return "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0 Calibri;}}\\f0\\fs20\n" .. table.concat(body, "\n") .. "\n}"
end

-- ----- PDF (real binary PDF via the built-in PdfDocument API, no external library) -----
local function wrapTextToWidth(text, paint, maxWidth)
    local lines = {}
    local words = {}
    for w in tostring(text or ""):gmatch("%S+") do table.insert(words, w) end
    if #words == 0 then table.insert(lines, ""); return lines end
    local current = words[1]
    for i = 2, #words do
        local testLine = current .. " " .. words[i]
        if paint.measureText(testLine) <= maxWidth then
            current = testLine
        else
            table.insert(lines, current)
            current = words[i]
        end
    end
    table.insert(lines, current)
    return lines
end

local function mdToPDF(md, filePath)
    local blocks = parseMarkdownBlocks(md)

    local pageWidth, pageHeight = 595, 842
    local marginLeft, marginRight, marginTop, marginBottom = 50, 50, 50, 50
    local contentWidth = pageWidth - marginLeft - marginRight

    local pdf = PdfDocument()
    local pageNum = 1
    local pageInfo = PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNum).create()
    local page = pdf.startPage(pageInfo)
    local canvas = page.getCanvas()
    local y = marginTop

    local paintNormal = Paint()
    paintNormal.setAntiAlias(true)
    paintNormal.setColor(Color.BLACK)
    paintNormal.setTextSize(11)

    local paintBold = Paint()
    paintBold.setAntiAlias(true)
    paintBold.setColor(Color.BLACK)
    paintBold.setTypeface(Typeface.DEFAULT_BOLD)

    local lineColor = Paint()
    lineColor.setColor(Color.parseColor("#2196F3"))
    lineColor.setStrokeWidth(1.5)

    local function newPage()
        pdf.finishPage(page)
        pageNum = pageNum + 1
        pageInfo = PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNum).create()
        page = pdf.startPage(pageInfo)
        canvas = page.getCanvas()
        y = marginTop
    end

    local function ensureSpace(neededHeight)
        if y + neededHeight > pageHeight - marginBottom then newPage() end
    end

    local function drawWrapped(text, paint, lineHeight, indent)
        indent = indent or 0
        local wraplines = wrapTextToWidth(text, paint, contentWidth - indent)
        for _, ln in ipairs(wraplines) do
            ensureSpace(lineHeight)
            canvas.drawText(ln, marginLeft + indent, y + lineHeight - 4, paint)
            y = y + lineHeight
        end
    end

    for _, b in ipairs(blocks) do
        if b.type == "h1" then
            paintBold.setTextSize(20)
            ensureSpace(34)
            canvas.drawText(stripBoldMarkers(b.text), marginLeft, y + 20, paintBold)
            y = y + 26
            canvas.drawLine(marginLeft, y, pageWidth - marginRight, y, lineColor)
            y = y + 12
        elseif b.type == "h2" then
            paintBold.setTextSize(15)
            ensureSpace(28)
            y = y + 6
            canvas.drawText(stripBoldMarkers(b.text), marginLeft, y + 14, paintBold)
            y = y + 20
        elseif b.type == "h3" then
            paintBold.setTextSize(13)
            ensureSpace(20)
            canvas.drawText(stripBoldMarkers(b.text), marginLeft, y + 12, paintBold)
            y = y + 18
        elseif b.type == "bullet" then
            ensureSpace(16)
            canvas.drawText("-", marginLeft, y + 12, paintNormal)
            drawWrapped(stripBoldMarkers(b.text), paintNormal, 16, 14)
        elseif b.type == "para" then
            if b.text ~= "" then
                drawWrapped(stripBoldMarkers(b.text), paintNormal, 16, 0)
            end
        else
            y = y + 6
        end
    end

    pdf.finishPage(page)
    local fos = FileOutputStream(filePath)
    pdf.writeTo(fos)
    fos.close()
    pdf.close()
end

-- ----- DOCX (real OOXML Word document, hand-built zip, no external library) -----
local function utf8Bytes(s)
    return JavaString(tostring(s or "")).getBytes("UTF-8")
end

local function writeZipEntry(zos, name, content)
    local entry = ZipEntry(name)
    zos.putNextEntry(entry)
    zos.write(utf8Bytes(content))
    zos.closeEntry()
end

local function buildDocxBodyXML(md)
    local blocks = parseMarkdownBlocks(md)
    local paras = {}
    local function renderRuns(segs)
        local runs = ""
        for _, sg in ipairs(segs) do
            if sg.bold then
                runs = runs .. '<w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">' .. escapeXml(sg.text) .. '</w:t></w:r>'
            else
                runs = runs .. '<w:r><w:t xml:space="preserve">' .. escapeXml(sg.text) .. '</w:t></w:r>'
            end
        end
        return runs
    end
    for _, b in ipairs(blocks) do
        if b.type == "h1" then
            table.insert(paras, '<w:p><w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val="36"/></w:rPr><w:t xml:space="preserve">' .. escapeXml(stripBoldMarkers(b.text)) .. '</w:t></w:r></w:p>')
        elseif b.type == "h2" then
            table.insert(paras, '<w:p><w:pPr><w:spacing w:before="200" w:after="100"/></w:pPr><w:r><w:rPr><w:b/><w:sz w:val="28"/></w:rPr><w:t xml:space="preserve">' .. escapeXml(stripBoldMarkers(b.text)) .. '</w:t></w:r></w:p>')
        elseif b.type == "h3" then
            table.insert(paras, '<w:p><w:r><w:rPr><w:b/><w:sz w:val="24"/></w:rPr><w:t xml:space="preserve">' .. escapeXml(stripBoldMarkers(b.text)) .. '</w:t></w:r></w:p>')
        elseif b.type == "bullet" then
            local runs = '<w:r><w:t xml:space="preserve">- </w:t></w:r>' .. renderRuns(splitBoldSegments(b.text))
            table.insert(paras, '<w:p><w:pPr><w:ind w:left="360"/></w:pPr>' .. runs .. '</w:p>')
        elseif b.type == "para" then
            if b.text ~= "" then
                table.insert(paras, '<w:p>' .. renderRuns(splitBoldSegments(b.text)) .. '</w:p>')
            end
        end
    end
    return table.concat(paras, "\n")
end

local function mdToDOCX(md, filePath)
    local bodyXml = buildDocxBodyXML(md)
    local documentXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' ..
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' ..
        bodyXml ..
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/></w:sectPr></w:body></w:document>'

    local contentTypesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' ..
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' ..
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' ..
        '<Default Extension="xml" ContentType="application/xml"/>' ..
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' ..
        '</Types>'

    local relsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' ..
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' ..
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' ..
        '</Relationships>'

    local fos = FileOutputStream(filePath)
    local zos = ZipOutputStream(fos)
    writeZipEntry(zos, "[Content_Types].xml", contentTypesXml)
    writeZipEntry(zos, "_rels/.rels", relsXml)
    writeZipEntry(zos, "word/document.xml", documentXml)
    zos.close()
    fos.close()
end

-- ----- ODT (real OpenDocument Text, hand-built zip, no external library) -----
local function buildOdtBodyXML(md)
    local blocks = parseMarkdownBlocks(md)
    local paras = {}
    local function renderInline(segs)
        local out = ""
        for _, sg in ipairs(segs) do
            if sg.bold then out = out .. '<text:span text:style-name="Bold">' .. escapeXml(sg.text) .. '</text:span>'
            else out = out .. escapeXml(sg.text) end
        end
        return out
    end
    for _, b in ipairs(blocks) do
        if b.type == "h1" then
            table.insert(paras, '<text:p text:style-name="Heading1">' .. escapeXml(stripBoldMarkers(b.text)) .. '</text:p>')
        elseif b.type == "h2" then
            table.insert(paras, '<text:p text:style-name="Heading2">' .. escapeXml(stripBoldMarkers(b.text)) .. '</text:p>')
        elseif b.type == "h3" then
            table.insert(paras, '<text:p text:style-name="Heading3">' .. escapeXml(stripBoldMarkers(b.text)) .. '</text:p>')
        elseif b.type == "bullet" then
            table.insert(paras, '<text:p text:style-name="Bullet">- ' .. renderInline(splitBoldSegments(b.text)) .. '</text:p>')
        elseif b.type == "para" then
            if b.text ~= "" then
                table.insert(paras, '<text:p>' .. renderInline(splitBoldSegments(b.text)) .. '</text:p>')
            end
        end
    end
    return table.concat(paras, "\n")
end

local function mdToODT(md, filePath)
    local bodyXml = buildOdtBodyXML(md)
    local contentXml = '<?xml version="1.0" encoding="UTF-8"?>\n' ..
        '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" ' ..
        'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" ' ..
        'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" ' ..
        'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.2">' ..
        '<office:automatic-styles>' ..
        '<style:style style:name="Bold" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>' ..
        '<style:style style:name="Heading1" style:family="paragraph"><style:text-properties fo:font-weight="bold" fo:font-size="20pt"/></style:style>' ..
        '<style:style style:name="Heading2" style:family="paragraph"><style:text-properties fo:font-weight="bold" fo:font-size="15pt"/></style:style>' ..
        '<style:style style:name="Heading3" style:family="paragraph"><style:text-properties fo:font-weight="bold" fo:font-size="13pt"/></style:style>' ..
        '<style:style style:name="Bullet" style:family="paragraph"><style:paragraph-properties fo:margin-left="0.4in"/></style:style>' ..
        '</office:automatic-styles>' ..
        '<office:body><office:text>' .. bodyXml .. '</office:text></office:body>' ..
        '</office:document-content>'

    local manifestXml = '<?xml version="1.0" encoding="UTF-8"?>\n' ..
        '<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">' ..
        '<manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.text"/>' ..
        '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>' ..
        '</manifest:manifest>'

    local fos = FileOutputStream(filePath)
    local zos = ZipOutputStream(fos)
    writeZipEntry(zos, "mimetype", "application/vnd.oasis.opendocument.text")
    writeZipEntry(zos, "META-INF/manifest.xml", manifestXml)
    writeZipEntry(zos, "content.xml", contentXml)
    zos.close()
    fos.close()
end

-- ----- JSON / XML structured "resume schema" formats -----
-- These two are built straight from the structured form data, not from AI prose, so they are
-- always machine-valid with zero dependency on the AI getting markup syntax right.
local function resumeToJSONSchema(r)
    local data = {
        basics = {
            name = r.personal.fullName or "",
            email = r.personal.email or "",
            phone = r.personal.phone or "",
            address = r.personal.address or "",
            dateOfBirth = r.personal.dob or "",
            profiles = {}
        },
        objective = r.objective or "",
        education = {},
        work = {},
        skills = {},
        projects = {},
        references = {}
    }
    for k, v in pairs(r.personal.extras or {}) do
        table.insert(data.basics.profiles, {network = k, value = v})
    end
    for _, e in ipairs(r.education or {}) do
        table.insert(data.education, {institution = e.school or "", area = e.course or "", score = e.grade or "", date = e.year or ""})
    end
    for _, x in ipairs(r.experience or {}) do
        table.insert(data.work, {company = x.company or "", position = x.role or "", startDate = x.start or "", endDate = x.end_date or "", summary = x.details or ""})
    end
    if r.skills and r.skills ~= "" then
        for s in r.skills:gmatch("[^,]+") do
            table.insert(data.skills, {name = s:gsub("^%s+", ""):gsub("%s+$", "")})
        end
    end
    for _, p in ipairs(r.projects or {}) do
        table.insert(data.projects, {name = p.title or "", description = p.details or ""})
    end
    for _, ref in ipairs(r.reference or {}) do
        table.insert(data.references, {name = ref.name or "", position = ref.job or "", company = ref.company or "", email = ref.email or "", phone = ref.phone or ""})
    end
    local ok, encoded = pcall(cjson.encode, data)
    if ok then return encoded end
    return "{}"
end

local function resumeToXML(r)
    local x = {}
    table.insert(x, '<?xml version="1.0" encoding="UTF-8"?>')
    table.insert(x, '<resume>')
    table.insert(x, '<personal>')
    table.insert(x, '<fullName>' .. escapeXml(r.personal.fullName) .. '</fullName>')
    table.insert(x, '<email>' .. escapeXml(r.personal.email) .. '</email>')
    table.insert(x, '<phone>' .. escapeXml(r.personal.phone) .. '</phone>')
    table.insert(x, '<address>' .. escapeXml(r.personal.address) .. '</address>')
    table.insert(x, '<dateOfBirth>' .. escapeXml(r.personal.dob) .. '</dateOfBirth>')
    for k, v in pairs(r.personal.extras or {}) do
        local tag = k:gsub("%s+", "")
        table.insert(x, '<' .. tag .. '>' .. escapeXml(v) .. '</' .. tag .. '>')
    end
    table.insert(x, '</personal>')
    table.insert(x, '<objective>' .. escapeXml(r.objective) .. '</objective>')
    table.insert(x, '<education>')
    for _, e in ipairs(r.education or {}) do
        table.insert(x, '<entry><course>' .. escapeXml(e.course) .. '</course><school>' .. escapeXml(e.school) .. '</school><grade>' .. escapeXml(e.grade) .. '</grade><year>' .. escapeXml(e.year) .. '</year></entry>')
    end
    table.insert(x, '</education>')
    table.insert(x, '<experience>')
    for _, ex in ipairs(r.experience or {}) do
        table.insert(x, '<entry><company>' .. escapeXml(ex.company) .. '</company><role>' .. escapeXml(ex.role) .. '</role><start>' .. escapeXml(ex.start) .. '</start><end>' .. escapeXml(ex.end_date) .. '</end><details>' .. escapeXml(ex.details) .. '</details></entry>')
    end
    table.insert(x, '</experience>')
    table.insert(x, '<skills>' .. escapeXml(r.skills) .. '</skills>')
    table.insert(x, '<projects>')
    for _, p in ipairs(r.projects or {}) do
        table.insert(x, '<entry><title>' .. escapeXml(p.title) .. '</title><details>' .. escapeXml(p.details) .. '</details></entry>')
    end
    table.insert(x, '</projects>')
    table.insert(x, '<references>')
    for _, rf in ipairs(r.reference or {}) do
        table.insert(x, '<entry><name>' .. escapeXml(rf.name) .. '</name><job>' .. escapeXml(rf.job) .. '</job><company>' .. escapeXml(rf.company) .. '</company><email>' .. escapeXml(rf.email) .. '</email><phone>' .. escapeXml(rf.phone) .. '</phone></entry>')
    end
    table.insert(x, '</references>')
    table.insert(x, '</resume>')
    return table.concat(x, "\n")
end

-- ==================== TEXT-TO-SPEECH (READ ALOUD) ====================
-- Accessibility feature: never use service.speak() — always use android.speech.tts.TextToSpeech
-- with an OnInitListener so this remains usable on devices without a custom speech service.
local ttsEngine = nil
local ttsReady = false

local function initTTS(onReadyCb)
    if ttsEngine then
        if ttsReady and onReadyCb then onReadyCb() end
        return
    end
    pcall(function()
        ttsEngine = TextToSpeech(ctx, TextToSpeech.OnInitListener{
            onInit = function(status)
                if status == TextToSpeech.SUCCESS then
                    ttsReady = true
                    if onReadyCb then onReadyCb() end
                else
                    toast("Text-to-Speech engine failed to initialize on this device.")
                end
            end
        })
    end)
end

local function speakText(text)
    if not text or tostring(text) == "" then toast("Nothing to read aloud."); return end
    initTTS(function()
        local ok = pcall(function()
            ttsEngine.speak(tostring(text), TextToSpeech.QUEUE_FLUSH, nil, "resume_tts_" .. tostring(System.currentTimeMillis()))
        end)
        if not ok then
            pcall(function() ttsEngine.speak(tostring(text), TextToSpeech.QUEUE_FLUSH, nil) end)
        end
    end)
end

local function stopSpeaking()
    pcall(function() if ttsEngine then ttsEngine.stop() end end)
end

local function shutdownTTS()
    pcall(function() if ttsEngine then ttsEngine.shutdown() end end)
end

-- ==================== PREFERENCES & STATE ====================
local AI_PREFS = "ResumeBuilderPrefs"
local aiPrefs = ctx.getSharedPreferences(AI_PREFS, Context.MODE_PRIVATE)
local aiEditor = aiPrefs.edit()

local RESUME_DIR = tostring(ctx.getFilesDir()) .. "/Resumes/"
local resumeDirFile = File_CLASS(RESUME_DIR)
if not resumeDirFile.exists() then resumeDirFile.mkdirs() end

local cachedModels = {}
local MODELS_FILE = tostring(ctx.getCacheDir()) .. "/resume_models.json"

local currentResume = nil
local aiTaskCancelled = false

function getPref(key, defVal) return aiPrefs.getString(key, defVal) end
function setPref(key, value) aiEditor.putString(key, value); aiEditor.commit() end

function loadJSON(path, defaultVal)
    local f = io.open(path, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if content and content ~= "" then
            local ok, res = pcall(cjson.decode, content)
            if ok then return res end
        end
    end
    return defaultVal
end

function saveJSON(path, data)
    local f = io.open(path, "w")
    if f then
        local ok, encoded = pcall(cjson.encode, data)
        if ok then f:write(encoded) end
        f:close()
    end
end

-- ==================== AI PROVIDER CONFIG ====================
cachedModels = loadJSON(MODELS_FILE, {})

local DEFAULT_MODELS = {
    ["Gemini"] = {"gemini-2.5-pro", "gemini-2.5-flash"},
    ["OpenAI"] = {"gpt-4o", "gpt-4-turbo"},
    ["Groq"] = {"llama-3.3-70b-versatile", "mixtral-8x7b-32768"},
    ["OpenRouter"] = {"google/gemini-2.5-pro", "openai/gpt-4o", "anthropic/claude-3.5-sonnet", "meta-llama/llama-3.3-70b-instruct"}
}

function getProviderModels(provider)
    if cachedModels[provider] and #cachedModels[provider] > 0 then return cachedModels[provider] end
    return DEFAULT_MODELS[provider] or {"default"}
end

function getProvider() return getPref("ai_provider", "Gemini") end
function getApiKey() return getPref("api_key_" .. getProvider(), "") end
function getModel() return getPref("model_" .. getProvider(), getProviderModels(getProvider())[1]) end

function refreshModelsFromAPI(provider, apiKey, callbackUI)
    if apiKey == "" then toast("Please enter Secret API Key first."); return end
    toast("Connecting to " .. provider .. " servers...")
    local url, headers = "", {}

    if provider == "Gemini" then
        url = "https://generativelanguage.googleapis.com/v1beta/models?key=" .. apiKey
    elseif provider == "OpenAI" then
        url = "https://api.openai.com/v1/models"
        headers = { ["Authorization"] = "Bearer " .. apiKey }
    elseif provider == "Groq" then
        url = "https://api.groq.com/openai/v1/models"
        headers = { ["Authorization"] = "Bearer " .. apiKey }
    elseif provider == "OpenRouter" then
        url = "https://openrouter.ai/api/v1/models"
        headers = { ["Authorization"] = "Bearer " .. apiKey }
    end

    Http.get(url, headers, function(status, data)
        if status == 200 then
            local ok, res = pcall(cjson.decode, data)
            if ok then
                local newModels = {}
                if provider == "Gemini" and res.models then
                    for _, m in ipairs(res.models) do
                        if string.match(tostring(m.name), "models/") and string.match(tostring(m.supportedGenerationMethods), "generateContent") then
                            table.insert(newModels, m.name:gsub("models/", ""))
                        end
                    end
                elseif (provider == "OpenAI" or provider == "Groq" or provider == "OpenRouter") and res.data then
                    for _, m in ipairs(res.data) do table.insert(newModels, tostring(m.id)) end
                end

                if #newModels > 0 then
                    cachedModels[provider] = newModels
                    saveJSON(MODELS_FILE, cachedModels)
                    toast("Loaded " .. #newModels .. " models.")
                    if callbackUI then callbackUI() end
                else toast("No models found.") end
            else toast("Error parsing data.") end
        else toast("API Error: " .. status) end
    end)
end

-- Standard, non-streaming request. Kept as a reliable fallback if live streaming
-- (callAIStream below) cannot be used on a given network/device.
function callAI(prompt, uiCallback, attempt)
    attempt = attempt or 1
    if aiTaskCancelled then return end

    local provider = getProvider()
    local apiKey = getApiKey()
    local model = getModel()
    if apiKey == "" then uiCallback(nil, "API Key missing! Configure in Settings."); return end

    local function handleResponse(status, data)
        if aiTaskCancelled then return end

        if status == 200 then
            local ok, res = pcall(cjson.decode, data)
            if ok then
                local reply = nil
                if provider == "Gemini" and res.candidates and res.candidates[1] then
                    reply = res.candidates[1].content.parts[1].text
                elseif provider ~= "Gemini" and res.choices and res.choices[1] then
                    reply = res.choices[1].message.content
                end

                if reply then
                    uiCallback(reply, nil)
                else
                    uiCallback(nil, "Invalid Response from API.")
                end
            else
                uiCallback(nil, "JSON Parse Error from API.")
            end
        elseif status == 429 and attempt <= 5 then
            local delay = (2 ^ (attempt - 1)) * 1000
            ui(function() toast("Server Busy (Error 429). Retrying in " .. (delay/1000) .. " seconds...") end)
            uiH.postDelayed(Runnable{
                run = function()
                    if not aiTaskCancelled then callAI(prompt, uiCallback, attempt + 1) end
                end
            }, delay)
        else
            local errMsg = "Error " .. status
            if status == 429 then errMsg = "Error 429: Too Many Requests. API quota exceeded."
            elseif status == 401 then errMsg = "Error 401: Unauthorized. Please check if your API key is correct."
            elseif status == 503 then errMsg = "Error 503: Service Unavailable. Servers are down."
            end
            uiCallback(nil, errMsg)
        end
    end

    if provider == "Gemini" then
        if not string.match(model, "^models/") then model = "models/" .. model end
        local url = "https://generativelanguage.googleapis.com/v1beta/" .. model .. ":generateContent?key=" .. apiKey
        local payload = cjson.encode({contents = {{role="user", parts={{text=prompt}}}}})
        Http.post(url, payload, { ["Content-Type"] = "application/json" }, handleResponse)
    else
        local url = ""
        local headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. apiKey }

        if provider == "Groq" then
            url = "https://api.groq.com/openai/v1/chat/completions"
        elseif provider == "OpenRouter" then
            url = "https://openrouter.ai/api/v1/chat/completions"
            headers["HTTP-Referer"] = "https://intelligentresume.app"
            headers["X-Title"] = "Intelligent Resume Builder"
        else
            url = "https://api.openai.com/v1/chat/completions"
        end

        local payload = cjson.encode({ model = model, messages = {{role="user", content=prompt}}, max_tokens = 4000 })
        Http.post(url, payload, headers, handleResponse)
    end
end

-- Live-streaming request. Reads the response incrementally over a raw HttpURLConnection on a
-- background thread, decoding each Server-Sent-Events chunk as it arrives so the UI can show
-- the resume/letter/analysis being written in real time, instead of a static "please wait".
function callAIStream(prompt, onChunk, onDone, attempt)
    attempt = attempt or 1
    if aiTaskCancelled then return end

    local provider = getProvider()
    local apiKey = getApiKey()
    local model = getModel()
    if apiKey == "" then ui(function() onDone(nil, "API Key missing! Configure in Settings.") end); return end

    local url, payload = "", ""
    local headers = { ["Content-Type"] = "application/json", ["Accept"] = "text/event-stream" }

    if provider == "Gemini" then
        if not string.match(model, "^models/") then model = "models/" .. model end
        url = "https://generativelanguage.googleapis.com/v1beta/" .. model .. ":streamGenerateContent?alt=sse&key=" .. apiKey
        payload = cjson.encode({contents = {{role="user", parts={{text=prompt}}}}})
    else
        headers["Authorization"] = "Bearer " .. apiKey
        if provider == "Groq" then
            url = "https://api.groq.com/openai/v1/chat/completions"
        elseif provider == "OpenRouter" then
            url = "https://openrouter.ai/api/v1/chat/completions"
            headers["HTTP-Referer"] = "https://intelligentresume.app"
            headers["X-Title"] = "Intelligent Resume Builder"
        else
            url = "https://api.openai.com/v1/chat/completions"
        end
        payload = cjson.encode({ model = model, messages = {{role="user", content=prompt}}, max_tokens = 4000, stream = true })
    end

    Thread(Runnable{run=function()
        local fullText = ""
        local hitDone = false
        local ok, runErr = pcall(function()
            local conn = URL(url).openConnection()
            conn.setRequestMethod("POST")
            conn.setDoOutput(true)
            conn.setConnectTimeout(15000)
            conn.setReadTimeout(60000)
            for k, v in pairs(headers) do conn.setRequestProperty(k, v) end

            local outWriter = OutputStreamWriter(conn.getOutputStream(), "UTF-8")
            outWriter.write(payload)
            outWriter.flush()
            outWriter.close()

            local status = conn.getResponseCode()
            if status ~= 200 then
                if status == 429 and attempt <= 5 then
                    local delay = (2 ^ (attempt - 1)) * 1000
                    ui(function() toast("Server Busy (429). Retrying in " .. (delay/1000) .. "s...") end)
                    uiH.postDelayed(Runnable{run=function()
                        if not aiTaskCancelled then callAIStream(prompt, onChunk, onDone, attempt + 1) end
                    end}, delay)
                    hitDone = true
                    return
                end
                ui(function() onDone(nil, "Error " .. status) end)
                hitDone = true
                return
            end

            local reader = BufferedReader(InputStreamReader(conn.getInputStream(), "UTF-8"))
            while true do
                if aiTaskCancelled then break end
                local line = reader.readLine()
                if line == nil then break end
                line = tostring(line)
                if line:sub(1, 5) == "data:" then
                    local jsonPart = line:sub(6):gsub("^%s+", "")
                    if jsonPart == "[DONE]" then
                        break
                    else
                        local pok, parsed = pcall(cjson.decode, jsonPart)
                        if pok and parsed then
                            local delta = nil
                            if provider == "Gemini" then
                                if parsed.candidates and parsed.candidates[1] and parsed.candidates[1].content
                                   and parsed.candidates[1].content.parts and parsed.candidates[1].content.parts[1] then
                                    delta = parsed.candidates[1].content.parts[1].text
                                end
                            else
                                if parsed.choices and parsed.choices[1] and parsed.choices[1].delta then
                                    delta = parsed.choices[1].delta.content
                                end
                            end
                            if delta and delta ~= "" then
                                fullText = fullText .. delta
                                local snapshot = fullText
                                ui(function() if not aiTaskCancelled then onChunk(snapshot) end end)
                            end
                        end
                    end
                end
            end
            reader.close()
            conn.disconnect()
            hitDone = true
            if not aiTaskCancelled then
                ui(function() onDone(fullText, nil) end)
            end
        end)
        if not ok and not hitDone then
            ui(function() if not aiTaskCancelled then onDone(fullText, "Streaming error: " .. tostring(runErr)) end end)
        end
    end}).start()
end

-- ==================== DATA MODEL & SAVING ====================
function createNewResume()
    return {
        id = tostring(System.currentTimeMillis()),
        title = "Untitled Resume",
        personal = { fullName = "", address = "", email = "", phone = "", dob = "", extras = {} },
        education = {}, experience = {}, skills = "", objective = "", reference = {}, projects = {},
        exportFormatName = "PDF (.pdf)",
        exportExt = ".pdf",
        generatedMarkdown = nil
    }
end

function saveCurrentResume()
    if not currentResume then return end
    if currentResume.personal.fullName and currentResume.personal.fullName ~= "" then
        currentResume.title = currentResume.personal.fullName
    end
    saveJSON(RESUME_DIR .. currentResume.id .. ".json", currentResume)
end

function getAllResumes()
    local files = resumeDirFile.listFiles()
    local res = {}
    if files then
        for i=0, #files-1 do
            local r = loadJSON(files[i].getAbsolutePath(), nil)
            if r then table.insert(res, r) end
        end
    end
    return res
end

function deleteResume(id)
    local target = File_CLASS(RESUME_DIR .. id .. ".json")
    if target.exists() then target.delete() end
end

function duplicateResume(r)
    local copy = nil
    pcall(function()
        local encoded = cjson.encode(r)
        copy = cjson.decode(encoded)
    end)
    if not copy then return nil end
    copy.id = tostring(System.currentTimeMillis())
    copy.title = (r.title or "Resume") .. " (Copy)"
    saveJSON(RESUME_DIR .. copy.id .. ".json", copy)
    return copy
end

-- ==================== SHARE / COPY HELPERS ====================
function shareText(text, titleText)
    pcall(function()
        local sIntent = Intent(Intent.ACTION_SEND)
        sIntent.setType("text/plain")
        sIntent.putExtra(Intent.EXTRA_TEXT, text)
        sIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        local chooser = Intent.createChooser(sIntent, titleText or "Share")
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(chooser)
    end)
end

function copyText(text)
    pcall(function()
        ctx.getSystemService(Context.CLIPBOARD_SERVICE).setText(tostring(text))
        toast("Copied!")
    end)
end

-- ==================== BACKUP / RESTORE ====================
function backupAllResumes()
    local ok, err = pcall(function()
        local resumes = getAllResumes()
        local dir = File_CLASS(Env_CLASS.getExternalStoragePublicDirectory(Env_CLASS.DIRECTORY_DOWNLOADS), "Resumes")
        if not dir.exists() then dir.mkdirs() end
        local file = File_CLASS(dir, "all_resumes_backup.json")
        local f = io.open(file.getAbsolutePath(), "w")
        if f then
            f:write(cjson.encode(resumes))
            f:close()
            toast("Backed up " .. #resumes .. " resume(s) to Downloads/Resumes/all_resumes_backup.json")
        else
            toast("Failed to write backup file.")
        end
    end)
    if not ok then toast("Backup failed: " .. tostring(err)) end
end

function restoreFromBackup(onDoneCb)
    local ok, err = pcall(function()
        local dir = File_CLASS(Env_CLASS.getExternalStoragePublicDirectory(Env_CLASS.DIRECTORY_DOWNLOADS), "Resumes")
        local file = File_CLASS(dir, "all_resumes_backup.json")
        if not file.exists() then toast("No backup file found in Downloads/Resumes/."); return end
        local data = loadJSON(file.getAbsolutePath(), nil)
        if not data then toast("Backup file could not be read."); return end
        local count = 0
        for _, r in ipairs(data) do
            if r.id then
                saveJSON(RESUME_DIR .. r.id .. ".json", r)
                count = count + 1
            end
        end
        toast("Restored " .. count .. " resume(s).")
        if onDoneCb then onDoneCb() end
    end)
    if not ok then toast("Restore failed: " .. tostring(err)) end
end

-- ==================== EXPORT (now dispatches to a real builder per format) ====================
function exportResume(r)
    if not r.generatedMarkdown then toast("Please generate the resume first!"); return end
    local ok, err = pcall(function()
        local dir = File_CLASS(Env_CLASS.getExternalStoragePublicDirectory(Env_CLASS.DIRECTORY_DOWNLOADS), "Resumes")
        if not dir.exists() then dir.mkdirs() end
        local safeTitle = r.title:gsub("[%c%s]", "_")
        local ext = r.exportExt or ".md"
        local file = File_CLASS(dir, safeTitle .. ext)
        local filePath = file.getAbsolutePath()
        local md = r.generatedMarkdown

        if ext == ".pdf" then
            mdToPDF(md, filePath)
        elseif ext == ".docx" then
            mdToDOCX(md, filePath)
        elseif ext == ".odt" then
            mdToODT(md, filePath)
        elseif ext == ".doc" or ext == ".rtf" then
            local f = io.open(filePath, "w"); if f then f:write(mdToRTF(md)); f:close() end
        elseif ext == ".html" then
            local f = io.open(filePath, "w"); if f then f:write(mdToFullHtml(md, r.title)); f:close() end
        elseif ext == ".json" then
            local f = io.open(filePath, "w"); if f then f:write(resumeToJSONSchema(r)); f:close() end
        elseif ext == ".xml" then
            local f = io.open(filePath, "w"); if f then f:write(resumeToXML(r)); f:close() end
        elseif ext == ".txt" then
            local f = io.open(filePath, "w"); if f then f:write(stripMd(md)); f:close() end
        else
            local f = io.open(filePath, "w"); if f then f:write(md); f:close() end
        end

        toast("Exported to Downloads/Resumes/" .. safeTitle .. ext)
    end)
    if not ok then toast("Export failed: " .. tostring(err)) end
end

-- ==================== SETTINGS DIALOG ====================
function showSettingsDialog(onBackCb)
    local rootScroll = ScrollView(ctx)
    local layout = LinearLayout(ctx)
    layout.setOrientation(1)
    layout.setBackground(rounded(C.bg, 18))
    layout.setPadding(dp(30), dp(30), dp(30), dp(30))
    rootScroll.addView(layout)

    layout.addView(tv("AI Engine Settings", 18, C.green, true))
    layout.addView(tv("Select AI Provider:", 14, C.sub, true))
    local provSpin = Spinner(ctx)
    local providers = {"Gemini", "OpenAI", "Groq", "OpenRouter"}
    provSpin.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_item, providers))
    local curProv = getProvider()
    for i, p in ipairs(providers) do if p == curProv then provSpin.setSelection(i-1); break end end
    layout.addView(provSpin)

    layout.addView(tv("Select AI Model:", 14, C.sub, true))
    local modSpin = Spinner(ctx)
    layout.addView(modSpin)

    local btnFetch = makeBtn("Refresh Models", C.divider, C.text)
    layout.addView(btnFetch)

    layout.addView(tv("API Key Configuration", 14, C.sub, true))
    local keyInput = makeInput("Enter Secret API Key")
    layout.addView(keyInput)

    local function updateModelList(pName)
        local models = getProviderModels(pName)
        modSpin.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_item, models))
        local curMod = getPref("model_" .. pName, models[1])
        for i, m in ipairs(models) do if m == curMod then modSpin.setSelection(i-1); break end end
        keyInput.setText(getPref("api_key_" .. pName, ""))
    end
    updateModelList(curProv)

    provSpin.onItemSelected = function(l,v,p,i)
        local sel = providers[p+1]
        setPref("ai_provider", sel)
        updateModelList(sel)
    end
    modSpin.onItemSelected = function(l,v,p,i) setPref("model_" .. getProvider(), getProviderModels(getProvider())[p+1]) end
    btnFetch.setOnClickListener(View.OnClickListener{onClick=function()
        refreshModelsFromAPI(getProvider(), tostring(keyInput.getText()), function() updateModelList(getProvider()) end)
    end})
    keyInput.addTextChangedListener({onTextChanged=function(s) if s then setPref("api_key_" .. getProvider(), tostring(s)) end end})

    -- ===== RESUME LANGUAGE (with custom language support) =====
    layout.addView(tv("Resume Language", 16, C.primary, true))
    local langSpin = Spinner(ctx)
    local langs = {"English", "Spanish", "French", "German", "Indonesian", "Hindi", "Custom Language..."}
    langSpin.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_item, langs))

    local customLangInput = makeInput("Type any language, e.g. Nepali, Japanese, Arabic")
    local curLang = getPref("resume_language", "English")
    local isPreset = false
    for i, l in ipairs(langs) do
        if l == curLang then langSpin.setSelection(i-1); isPreset = true; break end
    end

    if isPreset then
        customLangInput.setVisibility(View.GONE)
    else
        langSpin.setSelection(#langs - 1)
        customLangInput.setText(curLang)
        customLangInput.setVisibility(View.VISIBLE)
    end

    langSpin.onItemSelected = function(l,v,p,i)
        local sel = langs[p+1]
        if sel == "Custom Language..." then
            customLangInput.setVisibility(View.VISIBLE)
            local typed = tostring(customLangInput.getText())
            if typed ~= "" then setPref("resume_language", typed) end
        else
            customLangInput.setVisibility(View.GONE)
            setPref("resume_language", sel)
        end
    end
    customLangInput.addTextChangedListener({onTextChanged=function(s)
        if s and tostring(s) ~= "" then setPref("resume_language", tostring(s)) end
    end})

    layout.addView(langSpin)
    layout.addView(customLangInput)

    local dlg = AlertDialog.Builder(ctx).setView(rootScroll).setCancelable(false).create()
    dlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent)
    dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)

    local function openLinkAndClose(url, currentDlg)
        pcall(function()
            local intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
        end)
        if currentDlg then currentDlg.dismiss() end
    end

    layout.addView(tv("Get API Keys (Opens in Browser)", 16, C.warn, true))
    layout.addView(makeBtn("Get Google Gemini Key", C.surface, C.primary).setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); openLinkAndClose("https://aistudio.google.com/app/apikey", dlg) end}))
    layout.addView(makeBtn("Get OpenAI Key", C.surface, C.primary).setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); openLinkAndClose("https://platform.openai.com/api-keys", dlg) end}))
    layout.addView(makeBtn("Get Groq Key", C.surface, C.primary).setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); openLinkAndClose("https://console.groq.com/keys", dlg) end}))
    layout.addView(makeBtn("Get OpenRouter Key", C.surface, C.primary).setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); openLinkAndClose("https://openrouter.ai/keys", dlg) end}))

    local btnRow = LinearLayout(ctx); btnRow.setOrientation(0)
    local btnClose = makeBtn("Back", C.surface, C.text); btnClose.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    local btnSave = makeBtn("Save", C.green, C.text); btnSave.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    btnRow.addView(btnClose); btnRow.addView(btnSave); layout.addView(btnRow)

    btnClose.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); dlg.dismiss(); if onBackCb then onBackCb() end end})
    btnSave.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); toast("Settings Saved"); dlg.dismiss(); if onBackCb then onBackCb() end end})

    dlg.show()
end

-- ==================== FORM BUILDERS (SECTIONS) ====================
function editPersonalDetails(onSaveCb)
    local sDlg = AlertDialog.Builder(ctx).create()
    local rootScroll = ScrollView(ctx)
    local layout = LinearLayout(ctx); layout.setOrientation(1); layout.setBackground(rounded(C.bg, 18)); layout.setPadding(dp(20),dp(20),dp(20),dp(20))
    rootScroll.addView(layout)

    local tabRow = LinearLayout(ctx); tabRow.setOrientation(0)
    local tabP = makeBtn("Personal Details", C.primary, C.text); tabP.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    local tabH = makeBtn("Help", C.surface, C.text); tabH.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    tabRow.addView(tabP); tabRow.addView(tabH); layout.addView(tabRow)

    local formContainer = LinearLayout(ctx); formContainer.setOrientation(1)
    layout.addView(formContainer)

    local helpContainer = LinearLayout(ctx); helpContainer.setOrientation(1); helpContainer.setVisibility(View.GONE)
    helpContainer.addView(tv("Here you can enter all your personal details for your resume. Use the Add Fields button at the bottom to include optional fields such as Nationality, LinkedIn profile, or custom Salary Claims.", 14, C.text, false))
    layout.addView(helpContainer)

    tabP.setOnClickListener(View.OnClickListener{onClick=function() formContainer.setVisibility(View.VISIBLE); helpContainer.setVisibility(View.GONE); tabP.setBackground(rounded(C.primary, 8)); tabH.setBackground(rounded(C.surface, 8)) end})
    tabH.setOnClickListener(View.OnClickListener{onClick=function() formContainer.setVisibility(View.GONE); helpContainer.setVisibility(View.VISIBLE); tabH.setBackground(rounded(C.primary, 8)); tabP.setBackground(rounded(C.surface, 8)) end})

    local inputs = {}
    local function addField(key, label)
        formContainer.addView(tv(label, 12, C.sub, true))
        local et = makeInput(label)
        et.setText(currentResume.personal[key] or currentResume.personal.extras[key] or "")
        inputs[key] = et
        formContainer.addView(et)
    end

    addField("fullName", "Full Name *")
    addField("address", "Address (Optional)")
    addField("email", "Email *")
    addField("phone", "Phone *")
    addField("dob", "Date of Birth (Optional)")

    for k, v in pairs(currentResume.personal.extras) do addField(k, k:gsub("^%l", string.upper)) end

    local btnAddFields = makeBtn("+ ADD FIELDS", C.divider, C.text)
    btnAddFields.setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect()
        local extraDlg = AlertDialog.Builder(ctx).create()
        local el = LinearLayout(ctx); el.setOrientation(1); el.setBackground(rounded(C.bg, 18)); el.setPadding(dp(20),dp(20),dp(20),dp(20))
        el.addView(tv("Add More Personal Info", 18, C.primary, true))
        local extraScroll = ScrollView(ctx); local cl = LinearLayout(ctx); cl.setOrientation(1); extraScroll.addView(cl); el.addView(extraScroll)

        local extraKeys = {"Nationality", "Marital Status", "Website", "LinkedIn", "Facebook", "Twitter", "Religion", "Passport", "Gender", "Driving Licence", "Place", "Salary Claim"}
        local checks = {}
        for _, k in ipairs(extraKeys) do
            local row = LinearLayout(ctx); row.setOrientation(0); row.setGravity(16)
            local cb = CheckBox(ctx); cb.setChecked(currentResume.personal.extras[k] ~= nil)
            checks[k] = cb
            row.addView(cb)
            row.addView(tv("Toggle " .. k, 14, C.text, false))
            cl.addView(row)
        end
        cl.addView(tv("Above given profile fields are most commonly used. If you need new fields, you can create them.", 12, C.sub, false))

        local bRowEx = LinearLayout(ctx); bRowEx.setOrientation(0)
        local bCancel = makeBtn("CANCEL", C.surface, C.text); bCancel.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
        local bCreate = makeBtn("CREATE", C.green, C.text); bCreate.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
        bRowEx.addView(bCancel); bRowEx.addView(bCreate); cl.addView(bRowEx)

        bCancel.setOnClickListener(View.OnClickListener{onClick=function() extraDlg.dismiss() end})
        bCreate.setOnClickListener(View.OnClickListener{onClick=function()
            for k, cb in pairs(checks) do
                if cb.isChecked() and not inputs[k] then
                    currentResume.personal.extras[k] = ""
                    addField(k, k)
                elseif not cb.isChecked() and inputs[k] then
                    currentResume.personal.extras[k] = nil
                    formContainer.removeView(inputs[k])
                    inputs[k] = nil
                end
            end
            extraDlg.dismiss()
        end})
        extraDlg.setView(el); extraDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); extraDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); extraDlg.show()
    end})
    formContainer.addView(btnAddFields)

    local btnRow = LinearLayout(ctx); btnRow.setOrientation(0)
    local btnBack = makeBtn("BACK", C.surface, C.text); btnBack.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    local btnSave = makeBtn("SAVE", C.green, C.text); btnSave.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    btnRow.addView(btnBack); btnRow.addView(btnSave); layout.addView(btnRow)

    btnBack.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); sDlg.dismiss() end})
    btnSave.setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect()
        currentResume.personal.fullName = tostring(inputs["fullName"].getText())
        currentResume.personal.address = tostring(inputs["address"].getText())
        currentResume.personal.email = tostring(inputs["email"].getText())
        currentResume.personal.phone = tostring(inputs["phone"].getText())
        currentResume.personal.dob = tostring(inputs["dob"].getText())
        for k, _ in pairs(currentResume.personal.extras) do currentResume.personal.extras[k] = tostring(inputs[k].getText()) end
        saveCurrentResume()
        sDlg.dismiss()
        if onSaveCb then onSaveCb() end
    end})

    sDlg.setView(rootScroll); sDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); sDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); sDlg.show()
end

function editListSection(title, listKey, fields, helpText, onSaveCb)
    local sDlg = AlertDialog.Builder(ctx).create()
    local layout = LinearLayout(ctx); layout.setOrientation(1); layout.setBackground(rounded(C.bg, 18)); layout.setPadding(dp(20),dp(20),dp(20),dp(20))
    layout.addView(tv(title, 18, C.primary, true))

    if helpText then
        local helpTv = tv(helpText, 12, C.sub, false)
        local hp = LinearLayout.LayoutParams(-1, -2); hp.setMargins(0,0,0,dp(10)); helpTv.setLayoutParams(hp)
        layout.addView(helpTv)
    end

    local listContainer = LinearLayout(ctx); listContainer.setOrientation(1)
    local scroll = ScrollView(ctx); local sp = LinearLayout.LayoutParams(-1, 0, 1); scroll.setLayoutParams(sp)
    scroll.addView(listContainer); layout.addView(scroll)

    local function renderList()
        listContainer.removeAllViews()
        for i, item in ipairs(currentResume[listKey]) do
            local card = LinearLayout(ctx); card.setOrientation(1); card.setBackground(rounded(C.surface, 8, 1, C.divider)); card.setPadding(dp(15),dp(15),dp(15),dp(15))
            local cp = LinearLayout.LayoutParams(-1, -2); cp.setMargins(0, 0, 0, dp(10)); card.setLayoutParams(cp)

            card.addView(tv(title .. " " .. i, 16, C.text, true))

            local btnDel = makeBtn("Delete this entry", C.danger, C.text)
            btnDel.setOnClickListener(View.OnClickListener{onClick=function() table.remove(currentResume[listKey], i); renderList() end})
            card.addView(btnDel)

            for _, f in ipairs(fields) do
                card.addView(tv(f.label, 12, C.sub, true))
                local et = makeInput(f.hint, f.multi)
                et.setText(item[f.key] or "")
                et.addTextChangedListener({onTextChanged=function(s) if s then item[f.key] = tostring(s) end end})
                card.addView(et)
            end
            listContainer.addView(card)
        end
    end
    renderList()

    local btnAdd = makeBtn("+ ADD NEW ENTRY", C.divider, C.text); layout.addView(btnAdd)

    local btnRow = LinearLayout(ctx); btnRow.setOrientation(0)
    local btnBack = makeBtn("BACK", C.surface, C.text); btnBack.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    local btnSave = makeBtn("SAVE", C.green, C.text); btnSave.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    btnRow.addView(btnBack); btnRow.addView(btnSave); layout.addView(btnRow)

    btnAdd.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); table.insert(currentResume[listKey], {}); renderList() end})
    btnBack.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); sDlg.dismiss() end})
    btnSave.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); saveCurrentResume(); sDlg.dismiss(); if onSaveCb then onSaveCb() end end})

    sDlg.setView(layout); sDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); sDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); sDlg.show()
end

function editSimpleText(title, key, hint, onSaveCb)
    local sDlg = AlertDialog.Builder(ctx).create()
    local layout = LinearLayout(ctx); layout.setOrientation(1); layout.setBackground(rounded(C.bg, 18)); layout.setPadding(dp(20),dp(20),dp(20),dp(20))
    layout.addView(tv("Enter " .. title .. " Details", 18, C.primary, true))

    local et = makeInput(hint, true)
    et.setText(currentResume[key] or "")
    layout.addView(et)

    local btnRow = LinearLayout(ctx); btnRow.setOrientation(0)
    local btnBack = makeBtn("BACK", C.surface, C.text); btnBack.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    local btnSave = makeBtn("SAVE SECTION", C.green, C.text); btnSave.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    btnRow.addView(btnBack); btnRow.addView(btnSave); layout.addView(btnRow)

    btnBack.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); sDlg.dismiss() end})
    btnSave.setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); currentResume[key] = tostring(et.getText()); saveCurrentResume(); sDlg.dismiss(); if onSaveCb then onSaveCb() end
    end})

    sDlg.setView(layout); sDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); sDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); sDlg.show()
end

-- ==================== I'M FEELING LUCKY (DUMMY DATA) ====================
function fillDummyData(renderCb)
    currentResume.personal.fullName = "Alex Johnson"
    currentResume.personal.email = "alex.johnson@example.com"
    currentResume.personal.phone = "+1 555 019 2834"
    currentResume.personal.address = "San Francisco, CA"
    currentResume.personal.dob = "15/08/1995"
    currentResume.personal.extras = { LinkedIn = "linkedin.com/in/alexj" }

    currentResume.education = {
        {course="B.S. Computer Science", school="Stanford University", grade="3.8 GPA", year="2018 - 2022"}
    }
    currentResume.experience = {
        {company="Tech Innovations Inc.", role="Software Developer", start="06/2022", end_date="Present", details="Developed scalable web applications.\nImproved database query performance by 40%."}
    }
    currentResume.skills = "Python, Lua, JavaScript, React, System Architecture, Agile Methodologies"
    currentResume.objective = "Highly motivated software developer seeking to leverage expertise in full-stack development to build innovative solutions."
    currentResume.projects = {
        {title="AI Vision Tool", details="Created an AI accessibility tool using Gemini API and Lua."}
    }
    saveCurrentResume()
    toast("Dummy Data Generated!")
    if renderCb then renderCb() end
end

-- ==================== STREAMING AI DIALOG (shared by every AI feature) ====================
function showStreamingGenerationDialog(titleText, prompt, onComplete)
    local dlg = AlertDialog.Builder(ctx).setCancelable(false).create()
    local layout = LinearLayout(ctx); layout.setOrientation(1); layout.setBackground(rounded(C.bg, 18)); layout.setPadding(dp(20),dp(20),dp(20),dp(20))
    layout.addView(tv(titleText, 18, C.primary, true))

    local statusTv = tv("Connecting to " .. getProvider() .. "...", 13, C.warn, false)
    layout.addView(statusTv)

    local liveTv = tv("", 13, C.text, false)
    liveTv.setTextIsSelectable(true)
    local liveScroll = ScrollView(ctx)
    liveScroll.addView(liveTv)
    local lsp = LinearLayout.LayoutParams(-1, 0, 1)
    lsp.setMargins(0, dp(10), 0, dp(10))
    liveScroll.setLayoutParams(lsp)
    layout.addView(liveScroll)

    local btnCancel = makeBtn("Cancel", C.danger, C.text)
    layout.addView(btnCancel)

    aiTaskCancelled = false
    btnCancel.setOnClickListener(View.OnClickListener{onClick=function()
        aiTaskCancelled = true
        dlg.dismiss()
        toast("Cancelled.")
    end})

    dlg.setView(layout)
    dlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent)
    dlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
    dlg.show()

    callAIStream(prompt,
        function(snapshot)
            statusTv.setText("Generating live...")
            liveTv.setText(snapshot)
            pcall(function() liveScroll.fullScroll(View.FOCUS_DOWN) end)
        end,
        function(fullText, err)
            if err then
                if not fullText or fullText == "" then
                    statusTv.setText("Streaming unavailable, retrying in standard mode...")
                    callAI(prompt, function(reply, err2)
                        ui(function()
                            if err2 then
                                statusTv.setText("Error: " .. err2)
                                btnCancel.setText("Close")
                            else
                                dlg.dismiss()
                                if onComplete then onComplete(reply) end
                            end
                        end)
                    end)
                else
                    statusTv.setText("Error: " .. err)
                    btnCancel.setText("Close")
                end
            else
                dlg.dismiss()
                if onComplete then onComplete(fullText) end
            end
        end
    )
end

-- ==================== AI LIVE EDITOR (real-time AI modification) ====================
-- Lets the user describe a change in plain language. The current resume JSON plus the
-- instruction is streamed to the AI live, which must return ONLY the updated JSON. That JSON
-- replaces the in-memory resume immediately once it finishes and is saved to disk.
function showAILiveEditor(onUpdateCb)
    local instructionDlg = AlertDialog.Builder(ctx).create()
    local layout = LinearLayout(ctx); layout.setOrientation(1); layout.setBackground(rounded(C.bg, 18)); layout.setPadding(dp(20),dp(20),dp(20),dp(20))
    layout.addView(tv("AI Live Editor", 18, C.purple, true))
    layout.addView(tv("Tell the AI what to change. Example: change phone to 9800000000, add skill Docker, set job title to Senior Developer.", 12, C.sub, false))

    local et = makeInput("Type your instruction here...", true)
    layout.addView(et)

    local btnRow = LinearLayout(ctx); btnRow.setOrientation(0)
    local btnCancel = makeBtn("Cancel", C.surface, C.text); btnCancel.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
    local btnApply = makeBtn("Apply Changes", C.purple, C.text); btnApply.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
    btnRow.addView(btnCancel); btnRow.addView(btnApply); layout.addView(btnRow)

    btnCancel.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); instructionDlg.dismiss() end})
    btnApply.setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect()
        local instruction = tostring(et.getText())
        if instruction == "" then toast("Please type an instruction first."); return end

        local rawData = ""
        pcall(function() rawData = cjson.encode(currentResume) end)

        local prompt = "You are a JSON data editor for a resume builder app. Below is the CURRENT resume data in JSON, followed by a user instruction describing changes to make.\n\n"
        prompt = prompt .. "RULES:\n"
        prompt = prompt .. "1. Apply ONLY the changes requested in the instruction.\n"
        prompt = prompt .. "2. Keep every other field exactly as it is.\n"
        prompt = prompt .. "3. Preserve the exact same JSON structure and keys as the input.\n"
        prompt = prompt .. "4. Output STRICTLY valid JSON only - no markdown, no code fences, no explanation, no extra text.\n\n"
        prompt = prompt .. "CURRENT JSON:\n" .. rawData .. "\n\n"
        prompt = prompt .. "USER INSTRUCTION:\n" .. instruction

        instructionDlg.dismiss()

        showStreamingGenerationDialog("AI Live Editor", prompt, function(fullText)
            local cleaned = cleanCodeBlocks(fullText)
            local ok, newData = pcall(cjson.decode, cleaned)
            if ok and newData and type(newData) == "table" and newData.personal then
                newData.id = currentResume.id
                newData.generatedMarkdown = currentResume.generatedMarkdown
                newData.exportFormatName = currentResume.exportFormatName
                newData.exportExt = currentResume.exportExt
                if not newData.education then newData.education = {} end
                if not newData.experience then newData.experience = {} end
                if not newData.reference then newData.reference = {} end
                if not newData.projects then newData.projects = {} end
                if not newData.personal.extras then newData.personal.extras = {} end
                currentResume = newData
                saveCurrentResume()
                toast("Resume updated by AI!")
                if onUpdateCb then onUpdateCb() end
            else
                toast("AI response could not be understood. Try rephrasing your instruction more simply.")
            end
        end)
    end})

    instructionDlg.setView(layout); instructionDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); instructionDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); instructionDlg.show()
end

-- ==================== AI ATS SCORE & FEEDBACK ====================
function showATSScoreDialog(r)
    if not r.generatedMarkdown then toast("Please generate the resume first!"); return end
    local ext = r.exportExt or ".md"
    if ext == ".json" or ext == ".xml" then
        toast("ATS scoring works on written resume formats, not structured JSON/XML. Change the format and regenerate first.")
        return
    end

    local prompt = "You are an expert ATS (Applicant Tracking System) resume auditor. Analyze the following resume content and provide:\n"
    prompt = prompt .. "1. An ATS Compatibility Score out of 100.\n"
    prompt = prompt .. "2. A short list of strengths (max 4 bullet points).\n"
    prompt = prompt .. "3. A short list of improvements needed (max 5 bullet points).\n"
    prompt = prompt .. "Keep the entire response under 200 words, in plain text only, no markdown symbols.\n\n"
    prompt = prompt .. "RESUME CONTENT:\n" .. stripMd(r.generatedMarkdown)

    showStreamingGenerationDialog("AI ATS Score & Feedback", prompt, function(fullText)
        local finalText = stripMd(cleanCodeBlocks(fullText))

        local resultDlg = AlertDialog.Builder(ctx).create()
        local rl = LinearLayout(ctx); rl.setOrientation(1); rl.setBackground(rounded(C.bg, 18)); rl.setPadding(dp(20),dp(20),dp(20),dp(20))
        rl.addView(tv("AI ATS Score & Feedback", 18, C.primary, true))
        local resultTv = tv(finalText, 14, C.text, false)
        resultTv.setTextIsSelectable(true)
        local sc = ScrollView(ctx); sc.addView(resultTv)
        local scp = LinearLayout.LayoutParams(-1, 0, 1); sc.setLayoutParams(scp)
        rl.addView(sc)

        local brow = LinearLayout(ctx); brow.setOrientation(0)
        local bRead = makeBtn("Read Aloud", C.purple, C.text); bRead.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
        local bClose = makeBtn("Close", C.danger, C.text); bClose.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
        bRead.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); speakText(finalText) end})
        bClose.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); stopSpeaking(); resultDlg.dismiss() end})
        brow.addView(bRead); brow.addView(bClose); rl.addView(brow)

        resultDlg.setView(rl); resultDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); resultDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
        resultDlg.setOnDismissListener(DialogInterface.OnDismissListener{onDismiss=function() stopSpeaking() end})
        resultDlg.show()
    end)
end

-- ==================== AI COVER LETTER GENERATOR (now with richer fields) ====================
function showCoverLetterDialog(r)
    local inputDlg = AlertDialog.Builder(ctx).create()
    local il = LinearLayout(ctx); il.setOrientation(1); il.setBackground(rounded(C.bg, 18)); il.setPadding(dp(20),dp(20),dp(20),dp(20))
    il.addView(tv("AI Cover Letter Generator", 18, C.primary, true))

    local jobInput = makeInput("Job Title (e.g. Senior Android Developer)")
    local companyInput = makeInput("Company Name (Optional)")
    local managerInput = makeInput("Hiring Manager Name (Optional)")
    local achievementInput = makeInput("Key Achievement to Highlight (Optional)", true)
    il.addView(jobInput); il.addView(companyInput); il.addView(managerInput); il.addView(achievementInput)

    il.addView(tv("Tone", 12, C.sub, true))
    local toneSpin = Spinner(ctx)
    local tones = {"Formal", "Confident", "Friendly", "Enthusiastic"}
    toneSpin.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_item, tones))
    il.addView(toneSpin)

    il.addView(tv("Letter Length", 12, C.sub, true))
    local lengthSpin = Spinner(ctx)
    local lengths = {"Short (about 150 words)", "Standard (about 250 words)", "Detailed (about 400 words)"}
    lengthSpin.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_item, lengths))
    lengthSpin.setSelection(1)
    il.addView(lengthSpin)

    local btnGen = makeBtn("Generate Cover Letter", C.green, C.text)
    il.addView(btnGen)
    local btnCancel = makeBtn("Cancel", C.surface, C.text)
    btnCancel.setOnClickListener(View.OnClickListener{onClick=function() inputDlg.dismiss() end})
    il.addView(btnCancel)

    btnGen.setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect()
        local job = tostring(jobInput.getText())
        local company = tostring(companyInput.getText())
        local manager = tostring(managerInput.getText())
        local achievement = tostring(achievementInput.getText())
        local tone = tones[toneSpin.getSelectedItemPosition() + 1]
        local lengthHint = lengths[lengthSpin.getSelectedItemPosition() + 1]
        if job == "" then toast("Please enter a job title."); return end
        inputDlg.dismiss()

        local rawData = ""
        pcall(function() rawData = cjson.encode(currentResume.personal) end)
        local lang = getPref("resume_language", "English")

        local prompt = "Write a professional cover letter in " .. lang .. " with a " .. tone .. " tone, " .. lengthHint .. ", for the position of '" .. job .. "'"
        if company ~= "" then prompt = prompt .. " at '" .. company .. "'" end
        prompt = prompt .. ".\n"
        if manager ~= "" then prompt = prompt .. "Address it to the hiring manager: " .. manager .. ".\n" end
        if achievement ~= "" then prompt = prompt .. "Specifically highlight this achievement: " .. achievement .. ".\n" end
        prompt = prompt .. "Output plain text only, no markdown symbols, no placeholders in square brackets unless absolutely necessary.\n\n"
        prompt = prompt .. "CANDIDATE PERSONAL INFO:\n" .. rawData .. "\n"
        prompt = prompt .. "SKILLS: " .. (currentResume.skills or "") .. "\n"
        prompt = prompt .. "OBJECTIVE: " .. (currentResume.objective or "")

        showStreamingGenerationDialog("Writing Cover Letter", prompt, function(fullText)
            local letterText = stripMd(cleanCodeBlocks(fullText))

            local resDlg = AlertDialog.Builder(ctx).create()
            local rl = LinearLayout(ctx); rl.setOrientation(1); rl.setBackground(rounded(C.bg, 18)); rl.setPadding(dp(20),dp(20),dp(20),dp(20))
            rl.addView(tv("Your Cover Letter", 18, C.primary, true))
            local letterTv = tv(letterText, 14, C.text, false)
            letterTv.setTextIsSelectable(true)
            local sc = ScrollView(ctx); sc.addView(letterTv)
            local scp = LinearLayout.LayoutParams(-1, 0, 1); sc.setLayoutParams(scp)
            rl.addView(sc)

            local brow = LinearLayout(ctx); brow.setOrientation(0)
            local bRead = makeBtn("Read", C.purple, C.text); bRead.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
            local bCopy = makeBtn("Copy", C.divider, C.text); bCopy.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
            local bShare = makeBtn("Share", C.divider, C.text); bShare.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
            local bClose = makeBtn("Close", C.danger, C.text); bClose.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
            bRead.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); speakText(letterText) end})
            bCopy.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); copyText(letterText) end})
            bShare.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); shareText(letterText, "Share Cover Letter") end})
            bClose.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); stopSpeaking(); resDlg.dismiss() end})
            brow.addView(bRead); brow.addView(bCopy); brow.addView(bShare); brow.addView(bClose); rl.addView(brow)

            resDlg.setView(rl); resDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); resDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
            resDlg.setOnDismissListener(DialogInterface.OnDismissListener{onDismiss=function() stopSpeaking() end})
            resDlg.show()
        end)
    end})

    inputDlg.setView(il); inputDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); inputDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); inputDlg.show()
end

-- ==================== PREVIEW / GENERATED RESULT ====================
function showGeneratedResumeDialog(r)
    local resDlg = AlertDialog.Builder(ctx).create()
    local rl = LinearLayout(ctx); rl.setOrientation(1); rl.setBackground(rounded(C.bg, 18)); rl.setPadding(dp(20),dp(20),dp(20),dp(20))
    rl.addView(tv("Your Resume (" .. (r.exportExt or ".md") .. ")", 20, C.primary, true))

    local ext = r.exportExt or ".md"
    local isStructured = (ext == ".json" or ext == ".xml")
    local rawContent = r.generatedMarkdown or ""

    local resumeTv = tv("", 14, C.text, false)
    if isStructured then
        resumeTv.setText(rawContent)
    else
        resumeTv.setText(Html.fromHtml(mdToHtml(rawContent)))
    end
    resumeTv.setTextIsSelectable(true)

    local textScroll = ScrollView(ctx)
    local tsp = LinearLayout.LayoutParams(-1, 0, 1)
    tsp.setMargins(0, dp(15), 0, dp(15))
    textScroll.setLayoutParams(tsp)
    textScroll.addView(resumeTv)
    rl.addView(textScroll)

    local plainText = isStructured and rawContent or stripMd(rawContent)

    local rBtnRowTTS = LinearLayout(ctx); rBtnRowTTS.setOrientation(0)
    local btnRead = makeBtn("Read Aloud", C.purple, C.text); btnRead.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    local btnStop = makeBtn("Stop", C.divider, C.text); btnStop.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    btnRead.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); speakText(plainText) end})
    btnStop.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); stopSpeaking() end})
    rBtnRowTTS.addView(btnRead); rBtnRowTTS.addView(btnStop)
    rl.addView(rBtnRowTTS)

    local rBtnRow = LinearLayout(ctx); rBtnRow.setOrientation(0)
    local btnCopy = makeBtn("Copy", C.divider, C.text); btnCopy.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    local btnShare = makeBtn("Share", C.divider, C.text); btnShare.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))
    local btnC = makeBtn("Close", C.danger, C.text); btnC.setLayoutParams(LinearLayout.LayoutParams(0, -2, 1))

    btnCopy.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); copyText(plainText) end})
    btnShare.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); shareText(plainText, "Share Resume") end})
    btnC.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); stopSpeaking(); resDlg.dismiss() end})

    rBtnRow.addView(btnCopy); rBtnRow.addView(btnShare); rBtnRow.addView(btnC); rl.addView(rBtnRow)
    resDlg.setView(rl); resDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); resDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)
    resDlg.setOnDismissListener(DialogInterface.OnDismissListener{onDismiss=function() stopSpeaking() end})
    resDlg.show()
end

-- ==================== BUILDER MAIN SCREEN ====================
function showBuilderScreen(onBackCb)
    local bDlg = AlertDialog.Builder(ctx).create()
    local rootScroll = ScrollView(ctx)
    local layout = LinearLayout(ctx); layout.setOrientation(1); layout.setBackground(rounded(C.bg, 18)); layout.setPadding(dp(20),dp(20),dp(20),dp(20))
    rootScroll.addView(layout)

    layout.addView(tv("Resume Builder", 22, C.primary, true))

    local btnLucky = makeBtn("I'm Feeling Lucky (Demo Data)", C.warn, Color.WHITE)
    layout.addView(btnLucky)

    local btnAILive = makeBtn("AI Live Editor (Edit With a Text Command)", C.purple, C.text)
    layout.addView(btnAILive)

    layout.addView(tv("Tap a section to fill in details.", 14, C.sub, false))

    local listContainer = LinearLayout(ctx); listContainer.setOrientation(1)
    layout.addView(listContainer)

    local function renderSections()
        listContainer.removeAllViews()

        local function addSec(title, isFilled, action)
            local b = makeBtn(title .. ". " .. (isFilled and "Filled." or "Not filled.") .. " Tap to edit.", C.surface, isFilled and C.green or C.text)
            b.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); action() end})
            listContainer.addView(b)
        end

        addSec("Personal Details", currentResume.personal.fullName ~= "", function() editPersonalDetails(renderSections) end)

        addSec("Education", #currentResume.education > 0, function()
            editListSection("Education", "education", {
                {key="course", label="Course / Degree", hint="Course or Degree field"},
                {key="school", label="School / University", hint="School or University field"},
                {key="grade", label="Grade / Score", hint="Grade or Score field"},
                {key="year", label="Year", hint="Year field"}
            }, "Add your educational background.", renderSections)
        end)

        addSec("Experience", #currentResume.experience > 0, function()
            editListSection("Experience", "experience", {
                {key="company", label="Company", hint="Company Name"},
                {key="role", label="Role / Job Title", hint="Job Title"},
                {key="start", label="Start Date", hint="dd/mm/yyyy"},
                {key="end_date", label="End Date", hint="dd/mm/yyyy or Present"},
                {key="details", label="Details", hint="Job Responsibilities", multi=true}
            }, nil, renderSections)
        end)

        addSec("Skills", currentResume.skills ~= "", function() editSimpleText("Skills", "skills", "e.g. Java, Python, Project Management", renderSections) end)
        addSec("Objective", currentResume.objective ~= "", function() editSimpleText("Objective", "objective", "e.g. Seeking a challenging position...", renderSections) end)

        addSec("Reference", #currentResume.reference > 0, function()
            editListSection("Reference", "reference", {
                {key="name", label="Reference Name", hint="Name"},
                {key="job", label="Job Title", hint="Job Title"},
                {key="company", label="Company Name", hint="Company"},
                {key="email", label="Email", hint="Email"},
                {key="phone", label="Phone", hint="Phone"}
            }, nil, renderSections)
        end)

        addSec("Projects", #currentResume.projects > 0, function()
            editListSection("Projects", "projects", {
                {key="title", label="Project Title", hint="Title"},
                {key="details", label="Details", hint="Description of the project", multi=true}
            }, nil, renderSections)
        end)
    end
    renderSections()

    btnLucky.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); fillDummyData(renderSections) end})
    btnAILive.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); showAILiveEditor(renderSections) end})

    -- Format Selection
    layout.addView(tv("Output Target Format", 16, C.primary, true))
    local formatSpin = Spinner(ctx)
    local formatsList = {
        "PDF (.pdf)", "DOCX (.docx)", "RTF (.rtf)", "TXT (.txt)",
        "HTML (.html)", "ODT (.odt)", "DOC (.doc)", "Markdown (.md)",
        "XML Resume (.xml)", "JSON Resume (.json)"
    }
    formatSpin.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_item, formatsList))
    local savedFormat = currentResume.exportFormatName or "PDF (.pdf)"
    for i, f in ipairs(formatsList) do if f == savedFormat then formatSpin.setSelection(i-1); break end end

    formatSpin.onItemSelected = function(l,v,p,i)
        local sel = formatsList[p+1]
        currentResume.exportFormatName = sel
        currentResume.exportExt = sel:match("%((%.%w+)%)") or ".md"
        saveCurrentResume()
    end
    local fLp = LinearLayout.LayoutParams(-1, -2); fLp.setMargins(0, dp(5), 0, dp(15))
    formatSpin.setLayoutParams(fLp)
    layout.addView(formatSpin)

    layout.addView(tv("DOC (.doc) is written as a Word-compatible rich text file, since real legacy binary .doc files cannot be built without an external library. Word and most word processors open this correctly despite the .doc extension.", 11, C.sub, false))

    local btnGenerate = makeBtn("Create Resume & Preview", C.primary, C.text)
    btnGenerate.setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect()

        local ext = currentResume.exportExt or ".pdf"

        if ext == ".json" or ext == ".xml" then
            currentResume.generatedMarkdown = (ext == ".json") and resumeToJSONSchema(currentResume) or resumeToXML(currentResume)
            saveCurrentResume()
            toast("Generated instantly from your saved data - no AI needed for this format.")
            showGeneratedResumeDialog(currentResume)
            return
        end

        local lang = getPref("resume_language", "English")
        local rawData = ""
        pcall(function() rawData = cjson.encode(currentResume) end)
        if rawData == "" then rawData = "Name: " .. currentResume.personal.fullName end

        local prompt = "You are an Expert ATS-Friendly Senior Resume Writer. Transform the provided raw data into a polished, well-structured resume.\n\n"
        prompt = prompt .. "Target Language: " .. lang .. "\n\n"
        prompt = prompt .. "FORMATTING RULES (use clean Markdown):\n"
        prompt = prompt .. "1. Use a single # heading for the candidate's full name.\n"
        prompt = prompt .. "2. Use ## headings for each section (Objective, Experience, Education, Skills, Projects, References).\n"
        prompt = prompt .. "3. Use - for bullet points under Experience and Projects.\n"
        prompt = prompt .. "4. Use **bold** sparingly, only for job titles or key terms.\n"
        prompt = prompt .. "5. No conversational filler, intro, or outro - output ONLY the resume content.\n\n"
        prompt = prompt .. "RAW DATA:\n" .. rawData

        showStreamingGenerationDialog("Generating Your Resume", prompt, function(fullText)
            currentResume.generatedMarkdown = fullText
            saveCurrentResume()
            showGeneratedResumeDialog(currentResume)
        end)
    end})
    layout.addView(btnGenerate)

    local btnClose = makeBtn("Back to Menu", C.surface, C.text)
    btnClose.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); saveCurrentResume(); bDlg.dismiss(); if onBackCb then onBackCb() end end})
    layout.addView(btnClose)

    bDlg.setView(rootScroll); bDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); bDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); bDlg.show()
end

-- ==================== RESUME OPTIONS MENU ====================
function showResumeOptionsDialog(r, refreshCb)
    local oDlg = AlertDialog.Builder(ctx).create()
    local ol = LinearLayout(ctx); ol.setOrientation(1); ol.setBackground(rounded(C.bg, 18)); ol.setPadding(dp(20),dp(20),dp(20),dp(20))
    ol.addView(tv("Options for: " .. r.title, 18, C.primary, true))

    ol.addView(makeBtn("Edit / Build Details", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss(); currentResume = r; showBuilderScreen(refreshCb)
    end}))

    ol.addView(makeBtn("Preview Generated Resume", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss()
        if r.generatedMarkdown and r.generatedMarkdown ~= "" then showGeneratedResumeDialog(r) else toast("Please Generate the resume first from the Builder.") end
    end}))

    ol.addView(makeBtn("Copy Resume Data", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss()
        if r.generatedMarkdown then
            local ext = r.exportExt or ".md"
            local isStructured = (ext == ".json" or ext == ".xml")
            copyText(isStructured and r.generatedMarkdown or stripMd(r.generatedMarkdown))
        else toast("Please Generate first.") end
    end}))

    ol.addView(makeBtn("Share Resume", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss()
        if r.generatedMarkdown then
            local ext = r.exportExt or ".md"
            local isStructured = (ext == ".json" or ext == ".xml")
            shareText(isStructured and r.generatedMarkdown or stripMd(r.generatedMarkdown), "Share Resume")
        else toast("Please Generate first.") end
    end}))

    ol.addView(makeBtn("Export (" .. (r.exportExt or ".md") .. ")", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss(); exportResume(r)
    end}))

    ol.addView(makeBtn("Change Export Format", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss()
        local fDlg = AlertDialog.Builder(ctx).create()
        local fl = LinearLayout(ctx); fl.setOrientation(1); fl.setBackground(rounded(C.bg, 18)); fl.setPadding(dp(20),dp(20),dp(20),dp(20))
        fl.addView(tv("Change Export Format", 18, C.primary, true))
        fl.addView(tv("This instantly converts your already-written resume to a new format, with no AI call needed. If you switch to or from JSON/XML Resume, tap Create Resume again afterward to regenerate properly.", 12, C.sub, false))

        local formatSpin = Spinner(ctx)
        local formatsList = {
            "PDF (.pdf)", "DOCX (.docx)", "RTF (.rtf)", "TXT (.txt)",
            "HTML (.html)", "ODT (.odt)", "DOC (.doc)", "Markdown (.md)",
            "XML Resume (.xml)", "JSON Resume (.json)"
        }
        formatSpin.setAdapter(ArrayAdapter(ctx, android.R.layout.simple_spinner_item, formatsList))
        local savedFormat = r.exportFormatName or "PDF (.pdf)"
        for i, f in ipairs(formatsList) do if f == savedFormat then formatSpin.setSelection(i-1); break end end
        fl.addView(formatSpin)

        local btnRow = LinearLayout(ctx); btnRow.setOrientation(0)
        local btnCancel2 = makeBtn("Cancel", C.surface, C.text); btnCancel2.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
        local btnApply2 = makeBtn("Apply", C.green, C.text); btnApply2.setLayoutParams(LinearLayout.LayoutParams(0,-2,1))
        btnRow.addView(btnCancel2); btnRow.addView(btnApply2); fl.addView(btnRow)

        btnCancel2.setOnClickListener(View.OnClickListener{onClick=function() fDlg.dismiss() end})
        btnApply2.setOnClickListener(View.OnClickListener{onClick=function()
            clickEffect()
            local sel = formatsList[formatSpin.getSelectedItemPosition() + 1]
            r.exportFormatName = sel
            r.exportExt = sel:match("%((%.%w+)%)") or ".md"
            currentResume = r
            saveCurrentResume()
            toast("Export format changed to " .. sel)
            fDlg.dismiss()
            if refreshCb then refreshCb() end
        end})

        fDlg.setView(fl); fDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); fDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); fDlg.show()
    end}))

    -- ===== AI TOOLS GROUP =====
    ol.addView(tv("AI Tools", 13, C.purple, true))

    ol.addView(makeBtn("AI Live Editor", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss(); currentResume = r
        showAILiveEditor(function() if refreshCb then refreshCb() end end)
    end}))

    ol.addView(makeBtn("AI ATS Score & Feedback", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss(); showATSScoreDialog(r)
    end}))

    ol.addView(makeBtn("AI Cover Letter Generator", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss(); currentResume = r; showCoverLetterDialog(r)
    end}))

    ol.addView(makeBtn("Read Resume Aloud", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss()
        if r.generatedMarkdown and r.generatedMarkdown ~= "" then
            local ext = r.exportExt or ".md"
            local isStructured = (ext == ".json" or ext == ".xml")
            speakText(isStructured and r.generatedMarkdown or stripMd(r.generatedMarkdown))
            toast("Reading resume aloud...")
        else
            toast("Please generate the resume first.")
        end
    end}))

    -- ===== MANAGE GROUP =====
    ol.addView(tv("Manage", 13, C.sub, true))

    ol.addView(makeBtn("Duplicate Resume", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss()
        local copy = duplicateResume(r)
        if copy then
            toast("Duplicated as \"" .. copy.title .. "\"")
        else
            toast("Could not duplicate this resume.")
        end
        if refreshCb then refreshCb() end
    end}))

    ol.addView(makeBtn("Rename", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss()
        local renDlg = AlertDialog.Builder(ctx).create()
        local rLay = LinearLayout(ctx); rLay.setOrientation(1); rLay.setBackground(rounded(C.bg, 18)); rLay.setPadding(dp(20),dp(20),dp(20),dp(20))
        rLay.addView(tv("Rename Resume", 18, C.primary, true))
        local et = makeInput("Enter new name"); et.setText(r.title); rLay.addView(et)
        local btnS = makeBtn("Save", C.green, C.text)
        btnS.setOnClickListener(View.OnClickListener{onClick=function()
            local txt = tostring(et.getText())
            if txt ~= "" then r.title = txt; currentResume = r; saveCurrentResume(); toast("Renamed"); renDlg.dismiss(); if refreshCb then refreshCb() end end
        end})
        rLay.addView(btnS)
        rLay.addView(makeBtn("Cancel", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function() renDlg.dismiss() end}))
        renDlg.setView(rLay); renDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); renDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); renDlg.show()
    end}))

    ol.addView(makeBtn("Delete", C.danger, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); oDlg.dismiss(); deleteResume(r.id); toast("Deleted"); if refreshCb then refreshCb() end
    end}))

    ol.addView(makeBtn("Back", C.divider, C.text).setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); oDlg.dismiss() end}))

    oDlg.setView(ol); oDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); oDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); oDlg.show()
end

-- ==================== MAIN MENU ====================
function showMainMenu()
    local rootScroll = ScrollView(ctx)
    local layout = LinearLayout(ctx); layout.setOrientation(1); layout.setBackground(rounded(C.bg, 18)); layout.setPadding(dp(20), dp(20), dp(20), dp(20))
    rootScroll.addView(layout)

    local title = tv("Intelligent Resume", 24, C.primary, true); title.setGravity(Gravity.CENTER)
    local tp = LinearLayout.LayoutParams(-1, -2); tp.setMargins(0, 0, 0, dp(4)); title.setLayoutParams(tp)
    layout.addView(title)

    local subtitle = tv("AI-Powered, Accessible Edition", 12, C.sub, false); subtitle.setGravity(Gravity.CENTER)
    local sp2 = LinearLayout.LayoutParams(-1, -2); sp2.setMargins(0, 0, 0, dp(20)); subtitle.setLayoutParams(sp2)
    layout.addView(subtitle)

    local builder = AlertDialog.Builder(ctx).setView(rootScroll).setCancelable(false)
    local mainDlg = builder.create()
    mainDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent)
    mainDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY)

    local savedList = LinearLayout(ctx); savedList.setOrientation(1)

    local function renderSaved()
        savedList.removeAllViews()
        local resumes = getAllResumes()
        if #resumes == 0 then
            savedList.addView(tv("No generated resumes found", 14, C.sub, false))
        else
            for _, r in ipairs(resumes) do
                local b = makeBtn(r.title, C.surface, C.text)
                b.setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); showResumeOptionsDialog(r, renderSaved) end})
                savedList.addView(b)
            end
        end
    end

    layout.addView(makeBtn("Create New Resume", C.green, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); currentResume = createNewResume(); showBuilderScreen(renderSaved)
    end}))

    layout.addView(tv("Saved Resumes", 18, C.sub, true))
    layout.addView(savedList)
    renderSaved()

    layout.addView(makeBtn("Settings & Models", C.divider, C.text).setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); showSettingsDialog() end}))
    layout.addView(makeBtn("Backup All Resumes", C.divider, C.text).setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); backupAllResumes() end}))
    layout.addView(makeBtn("Restore From Backup", C.divider, C.text).setOnClickListener(View.OnClickListener{onClick=function() clickEffect(); restoreFromBackup(renderSaved) end}))

    layout.addView(makeBtn("Help Guide", C.surface, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect()
        local hDlg = AlertDialog.Builder(ctx).create()
        local hl = LinearLayout(ctx); hl.setOrientation(1); hl.setBackground(rounded(C.bg, 18)); hl.setPadding(dp(20),dp(20),dp(20),dp(20))
        hl.addView(tv("Help Guide", 18, C.primary, true))
        local helpText = "1. Go to Settings and configure your AI API Key and Model.\n"
        helpText = helpText .. "2. Tap Create New Resume.\n"
        helpText = helpText .. "3. Select your desired Output Format, and optionally a Custom Language in Settings.\n"
        helpText = helpText .. "4. Try I'm Feeling Lucky or fill out the sections manually.\n"
        helpText = helpText .. "5. Use the AI Live Editor any time to update fields with a simple text command, like change my phone number to ...\n"
        helpText = helpText .. "6. Tap Create Resume to watch the AI write your resume live, in real time.\n"
        helpText = helpText .. "7. PDF, DOCX, ODT, RTF, HTML, TXT and Markdown are all built directly on your device for a reliable, correctly formatted file every time. JSON and XML Resume are generated instantly from your saved data, with no AI needed.\n"
        helpText = helpText .. "8. From a saved resume's Options menu you can also get an AI ATS Score and Feedback, generate a matching AI Cover Letter with tone and hiring manager details, change the export format instantly, duplicate the resume, or have it Read Aloud.\n"
        helpText = helpText .. "9. Use Backup All Resumes and Restore From Backup to keep a safe copy of everything in your Downloads folder.\n"
        helpText = helpText .. "10. Export, Copy, or Share your document instantly."
        hl.addView(tv(helpText, 14, C.text, false))
        local hb = makeBtn("Back", C.danger, C.text); hb.setOnClickListener(View.OnClickListener{onClick=function() hDlg.dismiss() end}); hl.addView(hb)
        hDlg.setView(hl); hDlg.getWindow().setBackgroundDrawableResource(android.R.color.transparent); hDlg.getWindow().setType(WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY); hDlg.show()
    end}))

    layout.addView(makeBtn("Exit", C.danger, C.text).setOnClickListener(View.OnClickListener{onClick=function()
        clickEffect(); stopSpeaking(); shutdownTTS(); mainDlg.dismiss()
    end}))

    mainDlg.show()
end

showMainMenu()