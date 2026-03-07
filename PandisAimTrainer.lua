-- Original script by akenial
-- Made better with the help of Claude AI by nezur
-- This script also works on normal players in games aswell, its mainly for Pandi's Aim Trainer

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local Camera = Workspace.CurrentCamera

local Config = {
    Aimbot = {
        Enabled = true,
        Key = "q",
        
        -- Smoothing
        BaseSmoothingMin = 0.05,
        BaseSmoothingMax = 0.1,
        
        -- Humanization
        HoldKey = true,
        ReactionTimeMin = 0.125,
        ReactionTimeMax = 0.245,
        MissChance = 8,
        OvershootChance = 15,
        FatigueEnabled = true,
        
        -- Aim Offset Control (pixels from perfect center)
        AimOffsetMin = 8,
        AimOffsetMax = 13,
        PerfectAimChance = 100,
        
        -- Jitter Control (hand tremor simulation)
        JitterMin = 0.5,
        JitterMax = 0.5,
        
        -- Tracking Prediction System (for moving targets)
        TrackingMode = true,
        PredictionTime = 0.15,
        PredictionAccuracy = 0.98,
        CorrectionDelay = 0.15,
        OvercorrectionMin = 1.15,
        OvercorrectionMax = 1.25,
        DirectionChangeThreshold = 0.3,
        
        -- Target selection
        MeshTargetPart = "HumanoidRootPart",
        FlowStateThreshold = 5,
        
        -- Safety limits
        MaxTargetsPerSession = 99999,
        SessionLengthMinutes = 99999,
    }
}

local LockedTarget = nil
local LastTargetPos = nil
local lastTargetLostTime = 0
local waitingForDelay = false
local currentSmoothness = 0.13
local aimOffset = Vector2.new(0, 0)
local sessionStartTime = tick()
local targetLockTime = 0
local hasOvershot = false
local correctingOvershoot = false
local targetsHit = 0
local lastMovementDirection = nil
local consecutiveOptimalPicks = 0
local lastTargetVelocity = Vector3.new(0, 0, 0)
local predictionErrorDetected = false
local errorDetectionTime = 0
local isTracking = false
local targetMovementHistory = {}
local overcorrectionActive = false
local overcorrectionEndTime = 0

-- Simulate human fatigue over time (performance degrades)
local function GetFatigueMultiplier()
    if not Config.Aimbot.FatigueEnabled then return 1 end
    
    local sessionTime = tick() - sessionStartTime
    local sessionHours = sessionTime / 3600
    
    -- 12% performance decrease after 1 hour, caps there
    local fatiguePercent = math.min(sessionHours * 0.12, 0.12)
    return 1 + fatiguePercent
end

-- Variable smoothing that changes per target
local function GetDynamicSmoothness()
    local baseSmoothness = math.random(
        Config.Aimbot.BaseSmoothingMin * 100,
        Config.Aimbot.BaseSmoothingMax * 100
    ) / 100
    
    -- Apply fatigue (makes aim slightly worse/slower)
    local fatigue = GetFatigueMultiplier()
    local smoothness = baseSmoothness * fatigue
    
    -- Random "distraction" spikes (5% chance of momentary worse aim)
    if math.random(1, 100) <= 5 then
        smoothness = smoothness * 1.4
    end
    
    -- Clamp to reasonable bounds
    return math.clamp(smoothness, 0.05, 0.35)
end

-- Simulate human reaction time variance
local function GetReactionDelay()
    local baseDelay = math.random(
        Config.Aimbot.ReactionTimeMin * 1000,
        Config.Aimbot.ReactionTimeMax * 1000
    ) / 1000
    
    -- Occasionally faster reactions (10% chance - anticipation)
    if math.random(1, 100) <= 10 then
        baseDelay = baseDelay * 0.7
    end
    
    -- Occasionally slower reactions (8% chance - distraction)
    if math.random(1, 100) <= 8 then
        baseDelay = baseDelay * 1.5
    end
    
    return baseDelay
end

-- Generate aim offset to simulate imperfect centering
local function GenerateAimOffset()
    -- Sometimes aim at perfect center (skilled players do this)
    if math.random(1, 100) <= Config.Aimbot.PerfectAimChance then
        return Vector2.new(0, 0)
    end
    
    -- Generate offset based on configured min/max with fatigue
    local fatigue = GetFatigueMultiplier()
    local minOffset = Config.Aimbot.AimOffsetMin
    local maxOffset = Config.Aimbot.AimOffsetMax * fatigue
    
    local offsetMagnitude = math.random(minOffset * 100, maxOffset * 100) / 100
    local offsetAngle = math.random(0, 360)
    
    local offsetX = offsetMagnitude * math.cos(math.rad(offsetAngle))
    local offsetY = offsetMagnitude * math.sin(math.rad(offsetAngle))
    
    return Vector2.new(offsetX, offsetY)
end

-- Generate micro-jitter for current frame
local function GenerateJitter()
    local jitterX = math.random(
        Config.Aimbot.JitterMin * -100,
        Config.Aimbot.JitterMax * 100
    ) / 100
    
    local jitterY = math.random(
        Config.Aimbot.JitterMin * -100,
        Config.Aimbot.JitterMax * 100
    ) / 100
    
    return jitterX, jitterY
end

-- Calculate target velocity and predict position with human-like errors
local function GetPredictedPosition()
    if not LockedTarget or not LastTargetPos then
        return nil, false
    end
    
    if not Config.Aimbot.TrackingMode then
        return LockedTarget.Position, false
    end
    
    local currentPos = LockedTarget.Position
    local currentVelocity = Vector3.new(
        currentPos.X - LastTargetPos.X,
        currentPos.Y - LastTargetPos.Y,
        currentPos.Z - LastTargetPos.Z
    )
    
    -- Calculate velocity magnitudes
    local velocityMagnitude = math.sqrt(
        currentVelocity.X^2 + currentVelocity.Y^2 + currentVelocity.Z^2
    )
    
    local lastVelocityMagnitude = math.sqrt(
        lastTargetVelocity.X^2 + lastTargetVelocity.Y^2 + lastTargetVelocity.Z^2
    )
    
    -- Target is stationary
    if velocityMagnitude < 0.05 then
        isTracking = false
        lastTargetVelocity = Vector3.new(0, 0, 0)
        predictionErrorDetected = false
        return currentPos, false
    end
    
    isTracking = true
    
    -- Detect significant direction change
    if velocityMagnitude > 0.1 and lastVelocityMagnitude > 0.1 then
        -- Normalize vectors and calculate dot product
        local currentDir = Vector3.new(
            currentVelocity.X / velocityMagnitude,
            currentVelocity.Y / velocityMagnitude,
            currentVelocity.Z / velocityMagnitude
        )
        
        local lastDir = Vector3.new(
            lastTargetVelocity.X / lastVelocityMagnitude,
            lastTargetVelocity.Y / lastVelocityMagnitude,
            lastTargetVelocity.Z / lastVelocityMagnitude
        )
        
        local dotProduct = (currentDir.X * lastDir.X) +
                          (currentDir.Y * lastDir.Y) +
                          (currentDir.Z * lastDir.Z)
        
        -- Direction changed significantly (>70 degrees)
        if dotProduct < Config.Aimbot.DirectionChangeThreshold and not predictionErrorDetected then
            predictionErrorDetected = true
            errorDetectionTime = tick()
        end
    end
    
    -- Handle prediction error (human keeps wrong prediction)
    if predictionErrorDetected then
        local timeSinceError = tick() - errorDetectionTime
        local correctionDelay = Config.Aimbot.CorrectionDelay + (math.random(-30, 70) / 1000)
        
        if timeSinceError < correctionDelay then
            -- Still using OLD prediction (human hasn't realized/corrected yet)
            local predictionTime = Config.Aimbot.PredictionTime
            local predictedPos = Vector3.new(
                LastTargetPos.X + (lastTargetVelocity.X * predictionTime * 60),
                LastTargetPos.Y + (lastTargetVelocity.Y * predictionTime * 60),
                LastTargetPos.Z + (lastTargetVelocity.Z * predictionTime * 60)
            )
            return predictedPos, true
        else
            -- Correction phase: overcorrect in new direction
            predictionErrorDetected = false
            overcorrectionActive = true
            overcorrectionEndTime = tick() + 0.15  -- Overcorrect for 150ms
            
            local overcorrectionMult = math.random(
                Config.Aimbot.OvercorrectionMin * 100,
                Config.Aimbot.OvercorrectionMax * 100
            ) / 100
            
            local predictionTime = Config.Aimbot.PredictionTime
            local predictedPos = Vector3.new(
                currentPos.X + (currentVelocity.X * predictionTime * 60 * overcorrectionMult),
                currentPos.Y + (currentVelocity.Y * predictionTime * 60 * overcorrectionMult),
                currentPos.Z + (currentVelocity.Z * predictionTime * 60 * overcorrectionMult)
            )
            
            lastTargetVelocity = currentVelocity
            return predictedPos, true
        end
    end
    
    -- Handle active overcorrection phase
    if overcorrectionActive then
        if tick() < overcorrectionEndTime then
            local overcorrectionMult = 1.2 + (math.random(0, 15) / 100)
            local predictionTime = Config.Aimbot.PredictionTime
            local predictedPos = Vector3.new(
                currentPos.X + (currentVelocity.X * predictionTime * 60 * overcorrectionMult),
                currentPos.Y + (currentVelocity.Y * predictionTime * 60 * overcorrectionMult),
                currentPos.Z + (currentVelocity.Z * predictionTime * 60 * overcorrectionMult)
            )
            lastTargetVelocity = currentVelocity
            return predictedPos, true
        else
            overcorrectionActive = false
        end
    end
    
    -- Normal tracking: predict with random accuracy variance
    local predictionTime = Config.Aimbot.PredictionTime + (math.random(-30, 50) / 1000)
    local accuracyVariance = Config.Aimbot.PredictionAccuracy + (math.random(-10, 10) / 100)
    
    local predictedPos = Vector3.new(
        currentPos.X + (currentVelocity.X * predictionTime * 60 * accuracyVariance),
        currentPos.Y + (currentVelocity.Y * predictionTime * 60 * accuracyVariance),
        currentPos.Z + (currentVelocity.Z * predictionTime * 60 * accuracyVariance)
    )
    
    lastTargetVelocity = currentVelocity
    return predictedPos, true
end

local function IsAimKeyDown()
    local keys = getpressedkeys()
    for _, k in ipairs(keys) do
        if k:lower() == Config.Aimbot.Key then 
            return true 
        end
    end
    return false
end

local function GetTargetFolder()
    local Maps = Workspace:FindFirstChild("Maps")
    if not Maps then return nil end
    
    for _, map in ipairs(Maps:GetChildren()) do
        local targets = map:FindFirstChild("Targets")
        if targets then
            return targets
        end
    end
    return nil
end

-- Human-like target selection (proximity-based with flow state)
local function GetNextTarget()
    local targetFolder = GetTargetFolder()
    if not targetFolder then return nil end

    -- Simulate miss/reaction failure
    if math.random(1, 100) <= Config.Aimbot.MissChance then
        consecutiveOptimalPicks = 0
        return nil
    end

    local potentialTargets = {}
    local mouseLoc = UserInputService:GetMouseLocation()

    -- Gather all visible targets
    for _, group in ipairs(targetFolder:GetChildren()) do
        local targetPart = nil

        if group.Name == "Mesh" then
            targetPart = group:FindFirstChild(Config.Aimbot.MeshTargetPart) 
                or group:FindFirstChild("Primary") 
                or group:FindFirstChildWhichIsA("BasePart")
        elseif group.Name == "Sphere" or group.Name == "Cube" then
            targetPart = group:FindFirstChild("Primary") or group
        end

        if targetPart and targetPart:IsA("BasePart") then
            local sPos, onScreen = Camera:WorldToScreenPoint(targetPart.Position)
            if onScreen then
                local dx = sPos.X - mouseLoc.X
                local dy = sPos.Y - mouseLoc.Y
                local dist = math.sqrt(dx*dx + dy*dy)
                table.insert(potentialTargets, {
                    Part = targetPart, 
                    Mag = dist, 
                    ScreenPos = Vector2.new(sPos.X, sPos.Y)
                })
            end
        end
    end

    if #potentialTargets == 0 then return nil end

    -- Apply directional momentum bias (humans continue in same direction)
    if lastMovementDirection then
        for _, data in ipairs(potentialTargets) do
            local targetDir = (data.ScreenPos - mouseLoc)
            local targetDirLength = math.sqrt(targetDir.X * targetDir.X + targetDir.Y * targetDir.Y)
            
            if targetDirLength > 0 then
                targetDir = Vector2.new(targetDir.X / targetDirLength, targetDir.Y / targetDirLength)
                
                -- Calculate alignment with previous movement direction (dot product)
                local alignment = (lastMovementDirection.X * targetDir.X) + (lastMovementDirection.Y * targetDir.Y)
                
                -- Targets in same direction feel "closer" (continuation bias)
                if alignment > 0.5 then  -- Within ~60 degrees
                    data.Mag = data.Mag * 0.7  -- Feels 30% closer
                elseif alignment < -0.3 then  -- Opposite direction
                    data.Mag = data.Mag * 1.3  -- Feels 30% farther
                end
            end
        end
    end

    -- Sort by effective distance (closest first)
    table.sort(potentialTargets, function(a, b)
        return a.Mag < b.Mag
    end)

    -- Decision making based on "flow state"
    local inFlowState = consecutiveOptimalPicks >= Config.Aimbot.FlowStateThreshold

    if inFlowState then
        -- In flow: 95% pick optimal target (locked in)
        if math.random(1, 100) <= 95 then
            consecutiveOptimalPicks = consecutiveOptimalPicks + 1
            return potentialTargets[1].Part
        else
            -- Rare break in concentration
            consecutiveOptimalPicks = 0
            if #potentialTargets >= 3 then
                return potentialTargets[math.random(1, 3)].Part
            end
        end
    else
        -- Normal state: 80% pick optimal target
        if math.random(1, 100) <= 80 then
            consecutiveOptimalPicks = consecutiveOptimalPicks + 1
            return potentialTargets[1].Part
        else
            -- Suboptimal choice (human error)
            consecutiveOptimalPicks = 0
            
            -- 15% from top 3, 5% from top 5
            if math.random(1, 100) <= 75 and #potentialTargets >= 3 then
                return potentialTargets[math.random(1, 3)].Part
            elseif #potentialTargets >= 5 then
                return potentialTargets[math.random(1, 5)].Part
            else
                return potentialTargets[1].Part
            end
        end
    end

    return potentialTargets[1].Part
end

-- Update movement direction for directional bias
local function UpdateMovementDirection()
    if LockedTarget then
        local mouseLoc = UserInputService:GetMouseLocation()
        
        -- Use predicted position if tracking
        local aimPos, _ = GetPredictedPosition()
        local sPos = Camera:WorldToScreenPoint(aimPos or LockedTarget.Position)
        
        local direction = Vector2.new(
            sPos.X - mouseLoc.X,
            sPos.Y - mouseLoc.Y
        )
        
        -- Calculate magnitude manually for Vector2
        local magnitude = math.sqrt(direction.X * direction.X + direction.Y * direction.Y)
        
        if magnitude > 0 then
            lastMovementDirection = Vector2.new(
                direction.X / magnitude,
                direction.Y / magnitude
            )
        end
    end
end

-- Safety check: auto-disable after limits
local function CheckSafetyLimits()
    local sessionMinutes = (tick() - sessionStartTime) / 60
    
    if targetsHit >= Config.Aimbot.MaxTargetsPerSession then
        Config.Aimbot.Enabled = false
        warn("[AIMBOT] Auto-disabled - Target limit reached (" .. targetsHit .. ")")
        return false
    end
    
    if sessionMinutes >= Config.Aimbot.SessionLengthMinutes then
        Config.Aimbot.Enabled = false
        warn("[AIMBOT] Auto-disabled - Session time limit reached (" .. math.floor(sessionMinutes) .. " minutes)")
        return false
    end
    
    return true
end

RunService.Render:Connect(function()
    if not Config.Aimbot.Enabled then return end
    if not CheckSafetyLimits() then return end
    
    local mouseLoc = UserInputService:GetMouseLocation()

    if Config.Aimbot.HoldKey then
        if IsAimKeyDown() then
            -- Check if target moved significantly (anti-jitter protection)
            if LockedTarget and LastTargetPos then
                local cp = LockedTarget.Position
                local lp = LastTargetPos
                local distMoved = math.sqrt(
                    (cp.X - lp.X)^2 + 
                    (cp.Y - lp.Y)^2 + 
                    (cp.Z - lp.Z)^2
                )
                
                if distMoved > 2 then  -- Target moved too much, release lock
                    LockedTarget = nil
                    hasOvershot = false
                    correctingOvershoot = false
                    predictionErrorDetected = false
                    isTracking = false
                end
            end

            -- Target acquisition with human reaction delay
            if not LockedTarget or not LockedTarget.Parent or not LockedTarget:IsDescendantOf(Workspace) then
                if not waitingForDelay then
                    waitingForDelay = true
                    lastTargetLostTime = tick()
                    
                    -- Randomize parameters for new target
                    currentSmoothness = GetDynamicSmoothness()
                    aimOffset = GenerateAimOffset()
                    hasOvershot = math.random(1, 100) <= Config.Aimbot.OvershootChance
                    correctingOvershoot = false
                    
                    -- Reset tracking variables
                    lastTargetVelocity = Vector3.new(0, 0, 0)
                    predictionErrorDetected = false
                    isTracking = false
                    overcorrectionActive = false
                    
                    -- Warmup period: first 10 targets have worse aim
                    if targetsHit < 10 then
                        currentSmoothness = currentSmoothness * 1.5
                    end
                end

                local timeSinceLost = tick() - lastTargetLostTime
                local requiredDelay = GetReactionDelay()
                
                if timeSinceLost >= requiredDelay then
                    LockedTarget = GetNextTarget()
                    if LockedTarget then
                        waitingForDelay = false
                        LastTargetPos = LockedTarget.Position
                        targetLockTime = tick()
                        targetsHit = targetsHit + 1
                        UpdateMovementDirection()
                    end
                end
            end
        else
            -- Key released, reset everything
            LockedTarget = nil
            LastTargetPos = nil
            waitingForDelay = false
            hasOvershot = false
            correctingOvershoot = false
            predictionErrorDetected = false
            isTracking = false
            lastTargetVelocity = Vector3.new(0, 0, 0)
            overcorrectionActive = false
        end
    end

    -- Aim execution with humanization and tracking prediction
    if LockedTarget and LockedTarget.Parent then
        LastTargetPos = LockedTarget.Position
        
        -- Get predicted position (handles tracking scenarios)
        local aimPosition, isPredicting = GetPredictedPosition()
        local sPos, onScreen = Camera:WorldToScreenPoint(aimPosition)

        if onScreen then
            local targetX = sPos.X + aimOffset.X
            local targetY = sPos.Y + aimOffset.Y
            
            -- Simulate overshoot behavior (common human trait)
            if hasOvershot and not correctingOvershoot then
                local timeSinceLock = tick() - targetLockTime
                if timeSinceLock < 0.15 then  -- First 150ms, overshoot
                    local overshootMult = 1.3 + (math.random(10, 40) / 100)
                    targetX = mouseLoc.X + (targetX - mouseLoc.X) * overshootMult
                    targetY = mouseLoc.Y + (targetY - mouseLoc.Y) * overshootMult
                else
                    correctingOvershoot = true
                end
            end
            
            -- Apply micro-jitter (simulates hand tremor) with configurable range
            local jitterX, jitterY = GenerateJitter()
            
            -- Variable smoothness per frame (humans don't move at constant speed)
            local frameSmoothing = currentSmoothness * (0.85 + math.random(0, 30) / 100)
            
            -- If tracking and predicting, slightly reduce smoothness (harder to track)
            if isPredicting and isTracking then
                frameSmoothing = frameSmoothing * 1.1
            end
            
            -- Execute mouse movement
            mousemoverel(
                (targetX - mouseLoc.X) * frameSmoothing + jitterX,
                (targetY - mouseLoc.Y) * frameSmoothing + jitterY
            )
        else
            -- Target off screen, release lock
            LockedTarget = nil
            hasOvershot = false
            correctingOvershoot = false
            predictionErrorDetected = false
            isTracking = false
        end
    else
        LockedTarget = nil
    end
end)
