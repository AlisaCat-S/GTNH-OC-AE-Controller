local computer = require("computer")
local http = require("http-method")
local component = require("component")
local json = require("json")
local me = component.me_interface
local meCpu = require("cpu")
local config = require("config")

local tasks = {}
local monitors = {}

function tasks.refreshStorage(data)
    -- data 是物品过滤表
    local item = me.getItemsInNetwork(data)
    local result = {}

    for _, j in pairs(item) do
        table.insert(result, {
            name = j.name,
            label = j.label,
            isCraftable = j.isCraftable,
            damage = j.damage,
            size = j.size,
            aspect = j.aspect
        })
    end

    http.put(config.path.items, {}, {result = result})
    print("ItemStorage Upload OK")
end

function tasks.refreshFluidStorage(_)
    -- 刷新流体库存，因为无法筛选，有内存溢出情况
    local fluids = me.getFluidsInNetwork()
    local result = {}

    for _, j in pairs(fluids) do
        table.insert(result, {
            name = j.name,
            label = j.label,
            isCraftable = j.isCraftable,
            amount = j.amount
        })
    end

    http.put(config.path.fluids, {}, {result = result})
    print("FluidStorage Upload OK")
end

function tasks.refreshEssentiaStorage(_)
    -- 刷新原质库存（因为无法筛选，有内存溢出情况）
    local fluids = me.getEssentiaInNetwork()
    local result = {}

    for _, j in pairs(fluids) do
        table.insert(result, {
            name = j.name,
            label = j.label,
            amount = j.amount,
            aspect = j.aspect
        })
    end

    http.put(config.path.essentia, {}, {result = result})
    print("Essentia Upload OK")
end

function tasks.requestItem(data)
    -- 请求制作物品，参数格式:
    --     data = {
    --         filter = {},
    --         amount = 1,
    --         prioritizePower = true,
    --         cpuName = "cpu1"
    --     }
    if data.filter == nil then data.filter = {} end

    local craftable = me.getCraftables(data.filter)[1]
    if craftable == nil then return "没有指定的物品: " .. json.encode(data.filter) end
    if data.amount == nil then data.amount = 1 end

    local result
    if data.cpuName ~= nil then
        if data.prioritizePower == nil then data.prioritizePower = true end
        result = craftable.request(data.amount, data.prioritizePower, data.cpuName)
    elseif data.prioritizePower ~= nil then
        result = craftable.request(data.amount, data.prioritizePower)
    else
        result = craftable.request(data.amount)
    end
    if result == nil then return "请求制造物品失败！", nil end

    local res = {
        item = craftable.getItemStack(),
        failed = result.hasFailed(),
        computing = result.isComputing(),
        done = {result = true, why = nil},
        canceled = {result = true, why = nil}
    }
    res.done.result, res.done.why = result.isDone()
    res.canceled.result, res.canceled.why = result.isCanceled()
    return "请求制造物品完成", res
end

function tasks.simpleCpusInfo(_)
    -- 获取所有cpu的简单信息
    
    local list = meCpu.getCpuList(false)
    for _, cpu in pairs(list) do
        if cpu.id ~= nil and cpu.id ~= "" then
            local _, code = http.put(config.path.cpu .. "/" .. cpu.id, {}, cpu)
            if code ~= 200 then
                http.post(config.path.cpu, {}, cpu)
            end
        end
    end
    print("simpleCpusInfo Upload OK")
end

function tasks.allCpusInfo(_)
    -- 获取所有cpu的详细信息
    local list = meCpu.getCpuList(true)
    for _, cpu in pairs(list) do
        if cpu.id ~= nil and cpu.id ~= "" then
            local _, code = http.put(config.path.cpu .. "/" .. cpu.id, {}, cpu)
            if code ~= 200 then
                http.post(config.path.cpu, {}, cpu)
            end
        end
    end
    print("allCpusInfo Upload OK")
end

function tasks.cpuDetail(data)
    -- 获取cpu的详细信息
    -- data.id: cpu 的ID
    if data.id == nil then return "没有提供 CPU 名称" end
    local details = meCpu.getCpuDetail(data.id)
    if details == nil then return "获取 " .. data.id .. " 的信息失败！" end
    http.put(config.path.cpu .. "/" .. data.id, {}, details)
end


function tasks.cancelMonitor(data)
    -- data.id 要取消的监控的id
    monitors[data.id] = nil
end

function tasks.monitors(_)
    -- data.id 要取消的监控的id
    local m = {}
    for key in pairs(monitors) do table.insert(m, key) end
    return "current monitors", {monitors = m}
end

function tasks.cpuMonitor(_)
    monitors.cpuMonitor = {
        data = {},  -- 存储CPU最后状态记录
        func = function(monitorData)
            local cpus = meCpu.getCpuList(true)
            local busyExists = false

            for _, cpu in pairs(cpus) do
                if cpu.id and cpu.id ~= "" then
                    -- 获取当前状态标识
                    local currentStatus = cpu.busy and "busy" or "idle"
                    -- 获取上次记录的状态
                    local lastStatus = monitorData[cpu.id]

                    -- BUSY状态强制更新
                    if cpu.busy then
                        http.put(config.path.cpu .. "/" .. cpu.id, {}, cpu)
                        monitorData[cpu.id] = currentStatus  -- 更新记录
                        busyExists = true
                        -- 调试日志
                        print(("CPU[%s] busy status updated: %s"):format(cpu.id, cpu.busy))
                    
                    -- IDLE状态仅在变化时更新
                    elseif currentStatus ~= lastStatus then
                        http.put(config.path.cpu .. "/" .. cpu.id, {}, cpu)
                        monitorData[cpu.id] = currentStatus
                        print(("CPU[%s] idle status updated"):format(cpu.id))
                    end
                end
            end

            -- 无繁忙CPU时移除监控器
            if not busyExists then
                monitors.cpuMonitor = nil
                print("Monitor removed: All CPUs are idle")
            end
        end
    }
    print("CPU monitor activated: real-time tracking started")
end

http.init(config.baseUrl, tasks)

while true do
    for _, monitor in pairs(monitors) do monitor.func(monitor.data) end

    -- 判断是否有 CPU monitor，有则跳过判断是否有 CPU 运行
    if not monitors.cpuMonitor then
        -- 判断是否有 CPU 运行，有则添加 CPU 监控器
        local list = meCpu.getCpuList(true)
        local hasBusyCpu = false
        for _, cpu in pairs(list) do
            if cpu.busy then
                hasBusyCpu = true
                break
            end
        end
        if hasBusyCpu and not monitors.cpuMonitor then
            tasks.cpuMonitor()
        end
    end

    local result, message = http.executeNextTask(config.path.task)
    print(result, message)
    os.sleep(config.sleep)
    computer.beep(500)
end
