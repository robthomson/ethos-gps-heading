local widgetLoader = assert(loadfile("widget.lua"))()

local function init()
    widgetLoader.init()
end

return {init = init}

