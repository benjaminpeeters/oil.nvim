-- Absolute, so a spec that changes the cwd (cd_on_enter) can still load modules
vim.opt.runtimepath:append(vim.fn.getcwd())

vim.o.swapfile = false
vim.bo.swapfile = false
require("tests.test_util").reset_editor()
