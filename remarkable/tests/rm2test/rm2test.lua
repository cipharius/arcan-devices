local devices = {}

RM2_HRES = 32761
RM2_VRES = 25318

function rm2_handler(source, status)
	if status.kind == "input" then
		rm2test_input(status)
	end
end

function net_open_handler(source, status)
	if status.kind == "segment_request" then
		local vid = accept_target(0, 0, rm2_handler)
		target_flags(vid, TARGET_ALLOWINPUT)
		target_flags(vid, TARGET_DRAINQUEUE)
	end
end

function rm2test()
	net_open("rm2@", net_open_handler)
end

function rm2test_input( iotbl )
	local device = devices[iotbl.devid]
	if iotbl.kind == "digital" then
		if not device then
			return
		end

		if iotbl.subid == 1 then
			device.active = iotbl.active
		end
	end

	if iotbl.kind ~= "touch" and iotbl.kind ~= "analog" then
		return
	end

	if not device then
		local x_axis = inputanalog_query(iotbl.devid, 0)
		local y_axis = inputanalog_query(iotbl.devid, 1)

		if not x_axis or not y_axis then
			error("Failed to query one of input device (devid " .. tostring(iotbl.devid) .. ") axis metadata")
		end

		device = {
			x_min = x_axis.lower_bound or 0,
			x_max = x_axis.upper_bound or 0,
			y_min = y_axis.lower_bound or 0,
			y_max = y_axis.upper_bound or 0,
			x = 0,
			y = 0,
			active = false,
		}
		devices[iotbl.devid] = device
	end

	local width = 10

	if iotbl.kind == "touch" then
		device.x_min = 0
		device.x_max = 21147
		device.y_min = 0
		device.y_max = 15728

		device.x = (iotbl.x - device.x_min) / (device.x_max - device.x_min) * VRESW - width / 2
		device.y = (iotbl.y - device.y_min) / (device.y_max - device.y_min) * VRESH - width / 2
		device.active = iotbl.active
	elseif iotbl.kind == "analog" then
		if iotbl.subid == 0 then
			device.x = iotbl.samples[1]
		elseif iotbl.subid == 1 then
			device.y = iotbl.samples[1]
		end
	end

	local vid
	if device.active then
		vid = color_surface(width, width, 255, 0, 0)
	else
		vid = color_surface(width, width, 0, 0, 255)
	end
	move_image(vid, device.x, device.y)
	expire_image(vid, 10)
	show_image(vid)
end
