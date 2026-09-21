-- Colour entries by what they are: by file extension, by a few exact names, and
-- for a symlink by what it points at. Fork addition, used as the default
-- view_options.highlight_filename.
--
-- This replaces a set of `syntax match /name\.ext$/` rules. Those depended on the
-- file name being the last thing on the line, which stops being true as soon as
-- a column is rendered to the right of the name. A per-entry hook does not care
-- where the name sits.
--
-- The groups carry no colours of their own (see _get_highlights in init.lua): a
-- colorscheme or config assigns them, and without one entries look like plain
-- files, exactly as upstream.
local M = {}

---Highlight group per extension. Extensions are lowercase; matching ignores case.
---@type {[1]: string, [2]: string[]}[]
M.groups = {
  { "OilMarkdown", { "md", "rmd", "qmd" } },
  { "OilBash", { "sh" } },
  { "OilR", { "r" } },
  { "OilTex", { "tex", "bib" } },
  { "OilPython", { "py" } },
  { "OilCode", { "gms", "lua" } },
  { "OilPdf", { "pdf", "odt", "doc", "docx", "epub", "html", "htm" } },
  { "OilExec", { "app", "exe", "apk", "ipa", "pkg", "msi" } },
  {
    "OilData",
    {
      "csv", "json", "mif", "gdx", "tsv", "dat", "xls", "xlsx", "ods", "db", "rda", "rdata",
      "dta", "sas7bdat",
    },
  },
  {
    "OilAudio",
    { "mp3", "wav", "ogg", "m4a", "flac", "aac", "wma", "aiff", "opus", "mid", "midi" },
  },
  {
    "OilVideo",
    {
      "mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "3gp", "ogv",
      "vob",
    },
  },
  {
    "OilImage",
    {
      "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "svg", "ico", "raw", "cr2", "nef",
      "psd", "ai", "eps", "heic", "heif",
    },
  },
}

---Highlight group for an exact file name. Keys are lowercase; matching ignores
---case and is on the whole name. Takes precedence over the extension.
---@type table<string, string>
M.names = {
  ["readme.md"] = "OilReadme",
}

local ext_to_group = {}
for _, group in ipairs(M.groups) do
  for _, ext in ipairs(group[2]) do
    ext_to_group[ext] = group[1]
  end
end

---@param name string
---@return string|nil
M.group_for_name = function(name)
  local lower = name:lower()
  if M.names[lower] then
    return M.names[lower]
  end
  local ext = lower:match("%.([^.]+)$")
  return ext and ext_to_group[ext] or nil
end

---Default for view_options.highlight_filename.
---
---Returning nil means "use oil's own group", and it must stay nil for
---directories, hidden entries, link targets and orphan links: those groups carry
---the colours that mark them as such.
---@param entry oil.Entry
---@param is_hidden boolean
---@param is_link_target boolean
---@param is_link_orphan boolean
---@return string|nil
M.highlight_filename = function(entry, is_hidden, is_link_target, is_link_orphan)
  if is_link_target or is_link_orphan then
    return nil
  end
  if entry.type == "directory" or entry.type == "socket" then
    return nil
  end

  if entry.type == "link" then
    -- A link looks like what it points at
    local target_is_dir = entry.meta.link_stat.type == "directory"
    if is_hidden then
      return target_is_dir and "OilDirHidden" or nil
    end
    local by_name = M.names[entry.name:lower()]
    if by_name then
      return by_name
    end
    if target_is_dir then
      return "OilDir"
    end
    return M.group_for_name(entry.name)
  end

  if is_hidden then
    return nil
  end
  return M.group_for_name(entry.name)
end

return M
