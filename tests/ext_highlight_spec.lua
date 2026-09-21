local ext_highlight = require("oil.ext_highlight")

---@param name string
---@param entry_type string
---@param target_type? string Type the link resolves to; nil for an orphan or a non-link
local function entry(name, entry_type, target_type)
  return {
    name = name,
    type = entry_type,
    meta = target_type and { link_stat = { type = target_type } } or nil,
  }
end

local hl = ext_highlight.highlight_filename

describe("ext_highlight", function()
  describe("group_for_name", function()
    it("maps an extension to its group", function()
      assert.equals("OilMarkdown", ext_highlight.group_for_name("notes.md"))
      assert.equals("OilPython", ext_highlight.group_for_name("run.py"))
      assert.equals("OilData", ext_highlight.group_for_name("table.csv"))
    end)

    it("ignores case in the extension", function()
      assert.equals("OilR", ext_highlight.group_for_name("script.R"))
      assert.equals("OilMarkdown", ext_highlight.group_for_name("analysis.Rmd"))
      assert.equals("OilMarkdown", ext_highlight.group_for_name("UPPER.MD"))
    end)

    it("prefers an exact name over the extension, ignoring case", function()
      assert.equals("OilReadme", ext_highlight.group_for_name("readme.md"))
      assert.equals("OilReadme", ext_highlight.group_for_name("README.md"))
    end)

    it("matches an exact name on the whole name only", function()
      assert.equals("OilMarkdown", ext_highlight.group_for_name("old_readme.md"))
    end)

    it("returns nil when nothing applies", function()
      assert.is_nil(ext_highlight.group_for_name("noext"))
      assert.is_nil(ext_highlight.group_for_name("notes.txt"))
      -- only the last extension counts
      assert.is_nil(ext_highlight.group_for_name("archive.tar.gz"))
    end)
  end)

  describe("highlight_filename", function()
    it("colours a plain file by its extension", function()
      assert.equals("OilMarkdown", hl(entry("file.md", "file"), false, false, false))
    end)

    -- nil means "use oil's own group". These groups carry the colours that mark an
    -- entry as a directory, as hidden, as a link target or as broken.
    it("leaves directories, hidden files, link targets and orphans to oil", function()
      assert.is_nil(hl(entry("docs.md", "directory"), false, false, false))
      assert.is_nil(hl(entry(".hidden.md", "file"), true, false, false))
      assert.is_nil(hl(entry("link.md", "link", "file"), false, true, false))
      assert.is_nil(hl(entry("broken.md", "link"), false, false, true))
    end)

    it("makes a link look like what it points at", function()
      assert.equals("OilDir", hl(entry("to_dir", "link", "directory"), false, false, false))
      assert.equals("OilPython", hl(entry("run.py", "link", "file"), false, false, false))
      assert.equals("OilReadme", hl(entry("Readme.md", "link", "file"), false, false, false))
      -- a link with no known extension keeps oil's link colour
      assert.is_nil(hl(entry("to_file", "link", "file"), false, false, false))
    end)

    it("only restyles a hidden link when it points at a directory", function()
      assert.equals("OilDirHidden", hl(entry(".to_dir", "link", "directory"), true, false, false))
      assert.is_nil(hl(entry(".to_file.md", "link", "file"), true, false, false))
    end)
  end)

  -- Upstream sets the default highlight_filename to nil after defining it, since
  -- its default is a no-op. Here the default does the colouring, so an upstream
  -- merge that brings that line back would switch all of it off without an error.
  it("is still the default after setup()", function()
    require("oil").setup()
    local hook = require("oil.config").view_options.highlight_filename
    assert.is_function(hook)
    assert.equals("OilMarkdown", hook(entry("file.md", "file"), false, false, false))
  end)
end)
