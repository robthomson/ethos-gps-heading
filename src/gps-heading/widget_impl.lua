local SENSOR_NAME = "GPS Heading"
local SENSOR_APP_ID = 0xEF01
local SENSOR_REFRESH_MS = 2500
local SENSOR_CREATE_RETRY_SECONDS = 5.0
local MIN_SAMPLE_SECONDS = 0.40
local MIN_MOVE_METERS = 2.0
local MIN_TRACK_SPEED_MPS = 0.25
local STALE_HEADING_SECONDS = 8.0
local EARTH_RADIUS_METERS = 6371000.0

local version = (system.getVersion and system.getVersion()) or {}

local state = {
    gpsRoot = nil,
    gpsRootMember = nil,
    gpsRootCategory = nil,
    latSource = nil,
    lonSource = nil,
    sensor = nil,
    sensorCreateRetryAt = 0,
    trackAnchorLat = nil,
    trackAnchorLon = nil,
    trackAnchorAt = nil,
    lastHeading = nil,
    lastHeadingAt = nil,
    lastPublished = nil,
    lastPublishMs = 0
}

local function versionAtLeast(major, minor, revision)
    local currentMajor = tonumber(version.major) or 0
    local currentMinor = tonumber(version.minor) or 0
    local currentRevision = tonumber(version.revision) or 0

    if currentMajor ~= major then
        return currentMajor > major
    end
    if currentMinor ~= minor then
        return currentMinor > minor
    end
    return currentRevision >= revision
end

local useRawValue = versionAtLeast(26, 1, 0)

local function nowMs()
    return math.floor(os.clock() * 1000)
end

local function sourceIsLive(source)
    local ok
    local value

    if not source then
        return false
    end

    if type(source.state) == "function" then
        ok, value = pcall(source.state, source)
        if ok and value == false then
            return false
        end
    end

    if type(source.category) == "function" then
        ok, value = pcall(source.category, source)
        if ok and value == CATEGORY_NONE then
            return false
        end
    end

    return true
end

local function safeMethod(source, methodName, default)
    if not source then
        return default
    end

    local method = source[methodName]
    if type(method) ~= "function" then
        return default
    end

    local ok, value = pcall(method, source)
    if ok then
        return value
    end
    return default
end

local function resolveThemeColor(constantName, fallback)
    local themeColor = lcd.themeColor
    local constant = _G[constantName]

    if type(themeColor) == "function" and constant ~= nil then
        local ok, value = pcall(themeColor, constant)
        if ok and value ~= nil then
            return value
        end
    end

    return fallback
end

local function resetGpsSources()
    state.gpsRoot = nil
    state.gpsRootMember = nil
    state.gpsRootCategory = nil
    state.latSource = nil
    state.lonSource = nil
end

local function resolveGpsSources()
    local gpsRoot

    if not sourceIsLive(state.gpsRoot) then
        resetGpsSources()
    end

    if not sourceIsLive(state.latSource) then
        state.latSource = nil
    end
    if not sourceIsLive(state.lonSource) then
        state.lonSource = nil
    end

    if not state.gpsRoot then
        gpsRoot = system.getSource({name = "GPS", category = CATEGORY_TELEMETRY_SENSOR})
        if sourceIsLive(gpsRoot) then
            state.gpsRoot = gpsRoot
            state.gpsRootMember = safeMethod(gpsRoot, "member", nil)
            state.gpsRootCategory = safeMethod(gpsRoot, "category", nil)
        end
    end

    if state.gpsRootMember ~= nil and state.gpsRootCategory ~= nil then
        if not state.latSource then
            state.latSource = system.getSource({
                member = state.gpsRootMember,
                category = state.gpsRootCategory,
                options = OPTION_LATITUDE
            })
        end
        if not state.lonSource then
            state.lonSource = system.getSource({
                member = state.gpsRootMember,
                category = state.gpsRootCategory,
                options = OPTION_LONGITUDE
            })
        end
    end

    if not state.latSource then
        state.latSource = system.getSource({name = "GPS", options = OPTION_LATITUDE})
    end
    if not state.lonSource then
        state.lonSource = system.getSource({name = "GPS", options = OPTION_LONGITUDE})
    end

    return state.latSource, state.lonSource
end

local function readPosition()
    local latSource
    local lonSource
    local lat
    local lon

    latSource, lonSource = resolveGpsSources()

    if sourceIsLive(latSource) and type(latSource.value) == "function" then
        lat = latSource:value()
    end
    if sourceIsLive(lonSource) and type(lonSource.value) == "function" then
        lon = lonSource:value()
    end

    if lat ~= nil and lon ~= nil and not (lat == 0 and lon == 0) then
        return tonumber(lat), tonumber(lon), "live"
    end

    return nil, nil, "missing"
end

local function detectProtocol()
    local crsfSource
    local sportSource
    local moduleNumber

    crsfSource = system.getSource({crsfId = 0x14, subIdStart = 0, subIdEnd = 1})
    if sourceIsLive(crsfSource) then
        moduleNumber = safeMethod(crsfSource, "module", 1)
        return "crsf", moduleNumber or 1
    end

    sportSource = system.getSource({appId = 0xF101})
    if sourceIsLive(sportSource) then
        moduleNumber = safeMethod(sportSource, "module", 0)
        return "sport", moduleNumber or 0
    end

    moduleNumber = safeMethod(state.gpsRoot or state.latSource or state.lonSource, "module", 0)
    return "diy", moduleNumber or 0
end

local function syncSensorMetadata(sensor, protocol, moduleNumber)
    if not sensor then
        return
    end

    pcall(sensor.name, sensor, SENSOR_NAME)
    pcall(sensor.appId, sensor, SENSOR_APP_ID)
    pcall(sensor.physId, sensor, 0)
    pcall(sensor.module, sensor, moduleNumber or 0)
    pcall(sensor.minimum, sensor, 0)
    pcall(sensor.maximum, sensor, 359)
    pcall(sensor.unit, sensor, UNIT_DEGREE)
    pcall(sensor.protocolUnit, sensor, UNIT_DEGREE)
    pcall(sensor.decimals, sensor, 0)
    pcall(sensor.protocolDecimals, sensor, 0)
end

local function ensureCustomSensor(protocol, moduleNumber)
    local sensor = state.sensor
    local now

    if sensor then
        syncSensorMetadata(sensor, protocol, moduleNumber)
        return sensor
    end

    sensor = system.getSource({category = CATEGORY_TELEMETRY_SENSOR, appId = SENSOR_APP_ID})
    if sensor then
        syncSensorMetadata(sensor, protocol, moduleNumber)
        state.sensor = sensor
        state.sensorCreateRetryAt = 0
        return sensor
    end

    now = os.clock()
    if now < (state.sensorCreateRetryAt or 0) then
        return nil
    end

    if not model.createSensor then
        state.sensorCreateRetryAt = now + SENSOR_CREATE_RETRY_SECONDS
        return nil
    end

    sensor = model.createSensor({type = SENSOR_TYPE_DIY})
    if not sensor then
        state.sensorCreateRetryAt = now + SENSOR_CREATE_RETRY_SECONDS
        return nil
    end

    syncSensorMetadata(sensor, protocol, moduleNumber)
    state.sensor = sensor
    state.sensorCreateRetryAt = 0
    return sensor
end

local function publishHeading(value, protocol, moduleNumber)
    local sensor
    local currentMs

    if value == nil then
        sensor = state.sensor
        if sensor and sensor.reset then
            pcall(sensor.reset, sensor)
        end
        state.lastPublished = nil
        state.lastPublishMs = 0
        return
    end

    sensor = ensureCustomSensor(protocol, moduleNumber)
    if not sensor then
        return
    end

    currentMs = nowMs()
    if state.lastPublished == value and (currentMs - state.lastPublishMs) < SENSOR_REFRESH_MS then
        return
    end

    if useRawValue and type(sensor.rawValue) == "function" then
        sensor:rawValue(value)
    else
        sensor:value(value)
    end

    state.lastPublished = value
    state.lastPublishMs = currentMs
end

local function atan2(y, x)
    if math.atan2 then
        return math.atan2(y, x)
    end
    return math.atan(y, x)
end

local function distanceMeters(lat1, lon1, lat2, lon2)
    local meanLat = math.rad((lat1 + lat2) * 0.5)
    local dx = math.rad(lon2 - lon1) * EARTH_RADIUS_METERS * math.cos(meanLat)
    local dy = math.rad(lat2 - lat1) * EARTH_RADIUS_METERS
    return math.sqrt(dx * dx + dy * dy)
end

local function bearingDegrees(lat1, lon1, lat2, lon2)
    local lat1r = math.rad(lat1)
    local lat2r = math.rad(lat2)
    local dlon = math.rad(lon2 - lon1)
    local y = math.sin(dlon) * math.cos(lat2r)
    local x = math.cos(lat1r) * math.sin(lat2r) - math.sin(lat1r) * math.cos(lat2r) * math.cos(dlon)
    return (math.deg(atan2(y, x)) + 360) % 360
end

local function cardinalHeading(heading)
    local points = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
    local index = math.floor((((heading or 0) + 22.5) % 360) / 45) + 1
    return points[index]
end

local function measurementText(text)
    text = tostring(text or "")
    text = text:gsub("%%", "W")
    text = text:gsub("°", ".")
    return text
end

local function getValueFontsForResolution(width, height)
    local key = string.format("%dx%d", width, height)
    local fontMap = {
        ["800x480"] = {FONT_XXS, FONT_XS, FONT_S, FONT_STD, FONT_L, FONT_XL, FONT_XXL, FONT_XXXXL},
        ["640x360"] = {FONT_XXS, FONT_XS, FONT_S, FONT_STD, FONT_L, FONT_XL},
        ["480x320"] = {FONT_XXS, FONT_XS, FONT_S, FONT_STD, FONT_L, FONT_XL},
        ["480x272"] = {FONT_XXS, FONT_XS, FONT_S, FONT_STD}
    }

    return fontMap[key] or fontMap["480x320"]
end

local function chooseLargestFittingFont(text, maxW, maxH, fonts)
    local bestFont = fonts[1]
    local bestW = 0
    local bestH = 0
    local measure = measurementText(text)

    for _, font in ipairs(fonts) do
        lcd.font(font)
        local width, height = lcd.getTextSize(measure)
        if width <= maxW and height <= maxH then
            bestFont = font
            bestW = width
            bestH = height
        end
    end

    lcd.font(bestFont)
    return bestFont, bestW, bestH
end

local function snapshotStatus(sourceMode, heading, headingAge)
    if sourceMode == "missing" then
        return "No GPS"
    end
    if heading == nil then
        return "-"
    end
    if headingAge ~= nil and headingAge > STALE_HEADING_SECONDS then
        return "Heading stale"
    end
    return "Tracking"
end

local function updateHeadingState()
    local lat
    local lon
    local sourceMode
    local protocol
    local moduleNumber
    local currentTime
    local anchorLat
    local anchorLon
    local anchorAt
    local distance
    local dt
    local speed
    local headingAge
    local roundedHeading

    lat, lon, sourceMode = readPosition()
    protocol, moduleNumber = detectProtocol()

    if lat == nil or lon == nil then
        state.trackAnchorLat = nil
        state.trackAnchorLon = nil
        state.trackAnchorAt = nil
        state.lastHeading = nil
        state.lastHeadingAt = nil
        publishHeading(nil, protocol, moduleNumber)

        return {
            heading = nil,
            cardinal = nil,
            protocol = protocol,
            sourceMode = sourceMode,
            status = snapshotStatus(sourceMode, nil, nil)
        }
    end

    currentTime = os.clock()
    anchorLat = state.trackAnchorLat
    anchorLon = state.trackAnchorLon
    anchorAt = state.trackAnchorAt

    if anchorLat ~= nil and anchorLon ~= nil and anchorAt ~= nil then
        dt = currentTime - anchorAt
        distance = distanceMeters(anchorLat, anchorLon, lat, lon)

        if dt >= MIN_SAMPLE_SECONDS and distance >= MIN_MOVE_METERS then
            speed = distance / math.max(dt, 0.001)
            if speed >= MIN_TRACK_SPEED_MPS then
                roundedHeading = math.floor(bearingDegrees(anchorLat, anchorLon, lat, lon) + 0.5) % 360
                state.lastHeading = roundedHeading
                state.lastHeadingAt = currentTime
            end

            state.trackAnchorLat = lat
            state.trackAnchorLon = lon
            state.trackAnchorAt = currentTime
        end
    else
        state.trackAnchorLat = lat
        state.trackAnchorLon = lon
        state.trackAnchorAt = currentTime
    end

    if state.lastHeading ~= nil then
        publishHeading(state.lastHeading, protocol, moduleNumber)
        headingAge = currentTime - (state.lastHeadingAt or currentTime)
    else
        publishHeading(nil, protocol, moduleNumber)
    end

    return {
        heading = state.lastHeading,
        cardinal = state.lastHeading and cardinalHeading(state.lastHeading) or nil,
        protocol = protocol,
        sourceMode = sourceMode,
        status = snapshotStatus(sourceMode, state.lastHeading, headingAge)
    }
end

local function buildRenderKey(snapshot)
    return table.concat({
        tostring(snapshot.heading),
        tostring(snapshot.cardinal),
        tostring(snapshot.protocol),
        tostring(snapshot.status)
    }, "|")
end

local function create()
    return {
        snapshot = {
            heading = nil,
            cardinal = nil,
            protocol = "diy",
            sourceMode = "missing",
            status = "No GPS"
        },
        renderKey = nil
    }
end

local function paint(widget)
    local width, height = lcd.getWindowSize()
    local dark = lcd.darkMode and lcd.darkMode()
    local primaryText = resolveThemeColor("THEME_PRIMARY_COLOR", dark and lcd.RGB(245, 247, 250) or lcd.RGB(30, 35, 42))
    local snapshot = widget.snapshot or {}
    local fonts = getValueFontsForResolution(width, height)
    local mainText
    local valueFont
    local valueW
    local valueH

    if snapshot.heading ~= nil then
        mainText = string.format("%03d°", snapshot.heading)
        valueFont, valueW, valueH = chooseLargestFittingFont(mainText, width * 0.82, height * 0.50, fonts)

        lcd.color(primaryText)
        lcd.font(valueFont)
        lcd.drawText(math.floor((width - valueW) / 2), math.floor((height - valueH) / 2 - valueH * 0.10), mainText)
    else
        mainText = snapshot.status or "No GPS"
        valueFont, valueW, valueH = chooseLargestFittingFont(mainText, width * 0.80, height * 0.36, fonts)

        lcd.color(primaryText)
        lcd.font(valueFont)
        lcd.drawText(math.floor((width - valueW) / 2), math.floor((height - valueH) / 2 - valueH * 0.10), mainText)
    end

end

local function wakeup(widget)
    local snapshot = updateHeadingState()
    local renderKey = buildRenderKey(snapshot)

    widget.snapshot = snapshot
    if widget.renderKey ~= renderKey then
        widget.renderKey = renderKey
        if lcd.isVisible == nil or lcd.isVisible() then
            lcd.invalidate()
        end
    end
end

local function configure()
end

local function read()
    return true
end

local function write()
    return true
end

local function close()
end

return {
    create = create,
    paint = paint,
    wakeup = wakeup,
    configure = configure,
    read = read,
    write = write,
    close = close
}
