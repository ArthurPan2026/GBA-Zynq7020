# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "AUDIO_SAMPLE_RATE_HZ" -parent ${Page_0}
  ipgui::add_param $IPINST -name "AXI_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "BRAM_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "COLORIMETRY" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ENABLE_BRAM_SOURCE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ENABLE_HDMI_AUDIO" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ENABLE_HLS_SOURCE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ENABLE_SCALER" -parent ${Page_0}
  ipgui::add_param $IPINST -name "ENABLE_VDMA_SOURCE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FIXED_FORMAT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FIXED_SOURCE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FORMAT_SELECT_MODE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "LINE_BUFFER_IMPLEMENTATION" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAX_INPUT_HEIGHT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAX_INPUT_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAX_SCALER_INPUT_HEIGHT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MAX_SCALER_INPUT_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "OUTPUT_COLOR_DEPTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "OUTPUT_COLOR_MODE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "SOURCE_SELECT_MODE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "YCC_RANGE" -parent ${Page_0}


}

proc update_PARAM_VALUE.AUDIO_SAMPLE_RATE_HZ { PARAM_VALUE.AUDIO_SAMPLE_RATE_HZ } {
	# Procedure called to update AUDIO_SAMPLE_RATE_HZ when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AUDIO_SAMPLE_RATE_HZ { PARAM_VALUE.AUDIO_SAMPLE_RATE_HZ } {
	# Procedure called to validate AUDIO_SAMPLE_RATE_HZ
	return true
}

proc update_PARAM_VALUE.AXI_ADDR_WIDTH { PARAM_VALUE.AXI_ADDR_WIDTH } {
	# Procedure called to update AXI_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AXI_ADDR_WIDTH { PARAM_VALUE.AXI_ADDR_WIDTH } {
	# Procedure called to validate AXI_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.BRAM_ADDR_WIDTH { PARAM_VALUE.BRAM_ADDR_WIDTH } {
	# Procedure called to update BRAM_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.BRAM_ADDR_WIDTH { PARAM_VALUE.BRAM_ADDR_WIDTH } {
	# Procedure called to validate BRAM_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.COLORIMETRY { PARAM_VALUE.COLORIMETRY } {
	# Procedure called to update COLORIMETRY when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.COLORIMETRY { PARAM_VALUE.COLORIMETRY } {
	# Procedure called to validate COLORIMETRY
	return true
}

proc update_PARAM_VALUE.ENABLE_BRAM_SOURCE { PARAM_VALUE.ENABLE_BRAM_SOURCE } {
	# Procedure called to update ENABLE_BRAM_SOURCE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ENABLE_BRAM_SOURCE { PARAM_VALUE.ENABLE_BRAM_SOURCE } {
	# Procedure called to validate ENABLE_BRAM_SOURCE
	return true
}

proc update_PARAM_VALUE.ENABLE_HDMI_AUDIO { PARAM_VALUE.ENABLE_HDMI_AUDIO } {
	# Procedure called to update ENABLE_HDMI_AUDIO when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ENABLE_HDMI_AUDIO { PARAM_VALUE.ENABLE_HDMI_AUDIO } {
	# Procedure called to validate ENABLE_HDMI_AUDIO
	return true
}

proc update_PARAM_VALUE.ENABLE_HLS_SOURCE { PARAM_VALUE.ENABLE_HLS_SOURCE } {
	# Procedure called to update ENABLE_HLS_SOURCE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ENABLE_HLS_SOURCE { PARAM_VALUE.ENABLE_HLS_SOURCE } {
	# Procedure called to validate ENABLE_HLS_SOURCE
	return true
}

proc update_PARAM_VALUE.ENABLE_SCALER { PARAM_VALUE.ENABLE_SCALER } {
	# Procedure called to update ENABLE_SCALER when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ENABLE_SCALER { PARAM_VALUE.ENABLE_SCALER } {
	# Procedure called to validate ENABLE_SCALER
	return true
}

proc update_PARAM_VALUE.ENABLE_VDMA_SOURCE { PARAM_VALUE.ENABLE_VDMA_SOURCE } {
	# Procedure called to update ENABLE_VDMA_SOURCE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.ENABLE_VDMA_SOURCE { PARAM_VALUE.ENABLE_VDMA_SOURCE } {
	# Procedure called to validate ENABLE_VDMA_SOURCE
	return true
}

proc update_PARAM_VALUE.FIXED_FORMAT { PARAM_VALUE.FIXED_FORMAT } {
	# Procedure called to update FIXED_FORMAT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FIXED_FORMAT { PARAM_VALUE.FIXED_FORMAT } {
	# Procedure called to validate FIXED_FORMAT
	return true
}

proc update_PARAM_VALUE.FIXED_SOURCE { PARAM_VALUE.FIXED_SOURCE } {
	# Procedure called to update FIXED_SOURCE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FIXED_SOURCE { PARAM_VALUE.FIXED_SOURCE } {
	# Procedure called to validate FIXED_SOURCE
	return true
}

proc update_PARAM_VALUE.FORMAT_SELECT_MODE { PARAM_VALUE.FORMAT_SELECT_MODE } {
	# Procedure called to update FORMAT_SELECT_MODE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FORMAT_SELECT_MODE { PARAM_VALUE.FORMAT_SELECT_MODE } {
	# Procedure called to validate FORMAT_SELECT_MODE
	return true
}

proc update_PARAM_VALUE.LINE_BUFFER_IMPLEMENTATION { PARAM_VALUE.LINE_BUFFER_IMPLEMENTATION } {
	# Procedure called to update LINE_BUFFER_IMPLEMENTATION when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.LINE_BUFFER_IMPLEMENTATION { PARAM_VALUE.LINE_BUFFER_IMPLEMENTATION } {
	# Procedure called to validate LINE_BUFFER_IMPLEMENTATION
	return true
}

proc update_PARAM_VALUE.MAX_INPUT_HEIGHT { PARAM_VALUE.MAX_INPUT_HEIGHT } {
	# Procedure called to update MAX_INPUT_HEIGHT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAX_INPUT_HEIGHT { PARAM_VALUE.MAX_INPUT_HEIGHT } {
	# Procedure called to validate MAX_INPUT_HEIGHT
	return true
}

proc update_PARAM_VALUE.MAX_INPUT_WIDTH { PARAM_VALUE.MAX_INPUT_WIDTH } {
	# Procedure called to update MAX_INPUT_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAX_INPUT_WIDTH { PARAM_VALUE.MAX_INPUT_WIDTH } {
	# Procedure called to validate MAX_INPUT_WIDTH
	return true
}

proc update_PARAM_VALUE.MAX_SCALER_INPUT_HEIGHT { PARAM_VALUE.MAX_SCALER_INPUT_HEIGHT } {
	# Procedure called to update MAX_SCALER_INPUT_HEIGHT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAX_SCALER_INPUT_HEIGHT { PARAM_VALUE.MAX_SCALER_INPUT_HEIGHT } {
	# Procedure called to validate MAX_SCALER_INPUT_HEIGHT
	return true
}

proc update_PARAM_VALUE.MAX_SCALER_INPUT_WIDTH { PARAM_VALUE.MAX_SCALER_INPUT_WIDTH } {
	# Procedure called to update MAX_SCALER_INPUT_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MAX_SCALER_INPUT_WIDTH { PARAM_VALUE.MAX_SCALER_INPUT_WIDTH } {
	# Procedure called to validate MAX_SCALER_INPUT_WIDTH
	return true
}

proc update_PARAM_VALUE.OUTPUT_COLOR_DEPTH { PARAM_VALUE.OUTPUT_COLOR_DEPTH } {
	# Procedure called to update OUTPUT_COLOR_DEPTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.OUTPUT_COLOR_DEPTH { PARAM_VALUE.OUTPUT_COLOR_DEPTH } {
	# Procedure called to validate OUTPUT_COLOR_DEPTH
	return true
}

proc update_PARAM_VALUE.OUTPUT_COLOR_MODE { PARAM_VALUE.OUTPUT_COLOR_MODE } {
	# Procedure called to update OUTPUT_COLOR_MODE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.OUTPUT_COLOR_MODE { PARAM_VALUE.OUTPUT_COLOR_MODE } {
	# Procedure called to validate OUTPUT_COLOR_MODE
	return true
}

proc update_PARAM_VALUE.SOURCE_SELECT_MODE { PARAM_VALUE.SOURCE_SELECT_MODE } {
	# Procedure called to update SOURCE_SELECT_MODE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.SOURCE_SELECT_MODE { PARAM_VALUE.SOURCE_SELECT_MODE } {
	# Procedure called to validate SOURCE_SELECT_MODE
	return true
}

proc update_PARAM_VALUE.YCC_RANGE { PARAM_VALUE.YCC_RANGE } {
	# Procedure called to update YCC_RANGE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.YCC_RANGE { PARAM_VALUE.YCC_RANGE } {
	# Procedure called to validate YCC_RANGE
	return true
}


proc update_MODELPARAM_VALUE.MAX_INPUT_WIDTH { MODELPARAM_VALUE.MAX_INPUT_WIDTH PARAM_VALUE.MAX_INPUT_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAX_INPUT_WIDTH}] ${MODELPARAM_VALUE.MAX_INPUT_WIDTH}
}

proc update_MODELPARAM_VALUE.MAX_INPUT_HEIGHT { MODELPARAM_VALUE.MAX_INPUT_HEIGHT PARAM_VALUE.MAX_INPUT_HEIGHT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAX_INPUT_HEIGHT}] ${MODELPARAM_VALUE.MAX_INPUT_HEIGHT}
}

proc update_MODELPARAM_VALUE.BRAM_ADDR_WIDTH { MODELPARAM_VALUE.BRAM_ADDR_WIDTH PARAM_VALUE.BRAM_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.BRAM_ADDR_WIDTH}] ${MODELPARAM_VALUE.BRAM_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.AXI_ADDR_WIDTH { MODELPARAM_VALUE.AXI_ADDR_WIDTH PARAM_VALUE.AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.AXI_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.ENABLE_BRAM_SOURCE { MODELPARAM_VALUE.ENABLE_BRAM_SOURCE PARAM_VALUE.ENABLE_BRAM_SOURCE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ENABLE_BRAM_SOURCE}] ${MODELPARAM_VALUE.ENABLE_BRAM_SOURCE}
}

proc update_MODELPARAM_VALUE.ENABLE_HLS_SOURCE { MODELPARAM_VALUE.ENABLE_HLS_SOURCE PARAM_VALUE.ENABLE_HLS_SOURCE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ENABLE_HLS_SOURCE}] ${MODELPARAM_VALUE.ENABLE_HLS_SOURCE}
}

proc update_MODELPARAM_VALUE.ENABLE_VDMA_SOURCE { MODELPARAM_VALUE.ENABLE_VDMA_SOURCE PARAM_VALUE.ENABLE_VDMA_SOURCE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ENABLE_VDMA_SOURCE}] ${MODELPARAM_VALUE.ENABLE_VDMA_SOURCE}
}

proc update_MODELPARAM_VALUE.SOURCE_SELECT_MODE { MODELPARAM_VALUE.SOURCE_SELECT_MODE PARAM_VALUE.SOURCE_SELECT_MODE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.SOURCE_SELECT_MODE}] ${MODELPARAM_VALUE.SOURCE_SELECT_MODE}
}

proc update_MODELPARAM_VALUE.FIXED_SOURCE { MODELPARAM_VALUE.FIXED_SOURCE PARAM_VALUE.FIXED_SOURCE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FIXED_SOURCE}] ${MODELPARAM_VALUE.FIXED_SOURCE}
}

proc update_MODELPARAM_VALUE.FORMAT_SELECT_MODE { MODELPARAM_VALUE.FORMAT_SELECT_MODE PARAM_VALUE.FORMAT_SELECT_MODE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FORMAT_SELECT_MODE}] ${MODELPARAM_VALUE.FORMAT_SELECT_MODE}
}

proc update_MODELPARAM_VALUE.FIXED_FORMAT { MODELPARAM_VALUE.FIXED_FORMAT PARAM_VALUE.FIXED_FORMAT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FIXED_FORMAT}] ${MODELPARAM_VALUE.FIXED_FORMAT}
}

proc update_MODELPARAM_VALUE.MAX_SCALER_INPUT_WIDTH { MODELPARAM_VALUE.MAX_SCALER_INPUT_WIDTH PARAM_VALUE.MAX_SCALER_INPUT_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAX_SCALER_INPUT_WIDTH}] ${MODELPARAM_VALUE.MAX_SCALER_INPUT_WIDTH}
}

proc update_MODELPARAM_VALUE.MAX_SCALER_INPUT_HEIGHT { MODELPARAM_VALUE.MAX_SCALER_INPUT_HEIGHT PARAM_VALUE.MAX_SCALER_INPUT_HEIGHT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MAX_SCALER_INPUT_HEIGHT}] ${MODELPARAM_VALUE.MAX_SCALER_INPUT_HEIGHT}
}

proc update_MODELPARAM_VALUE.ENABLE_SCALER { MODELPARAM_VALUE.ENABLE_SCALER PARAM_VALUE.ENABLE_SCALER } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ENABLE_SCALER}] ${MODELPARAM_VALUE.ENABLE_SCALER}
}

proc update_MODELPARAM_VALUE.LINE_BUFFER_IMPLEMENTATION { MODELPARAM_VALUE.LINE_BUFFER_IMPLEMENTATION PARAM_VALUE.LINE_BUFFER_IMPLEMENTATION } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.LINE_BUFFER_IMPLEMENTATION}] ${MODELPARAM_VALUE.LINE_BUFFER_IMPLEMENTATION}
}

proc update_MODELPARAM_VALUE.ENABLE_HDMI_AUDIO { MODELPARAM_VALUE.ENABLE_HDMI_AUDIO PARAM_VALUE.ENABLE_HDMI_AUDIO } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.ENABLE_HDMI_AUDIO}] ${MODELPARAM_VALUE.ENABLE_HDMI_AUDIO}
}

proc update_MODELPARAM_VALUE.AUDIO_SAMPLE_RATE_HZ { MODELPARAM_VALUE.AUDIO_SAMPLE_RATE_HZ PARAM_VALUE.AUDIO_SAMPLE_RATE_HZ } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AUDIO_SAMPLE_RATE_HZ}] ${MODELPARAM_VALUE.AUDIO_SAMPLE_RATE_HZ}
}

proc update_MODELPARAM_VALUE.OUTPUT_COLOR_MODE { MODELPARAM_VALUE.OUTPUT_COLOR_MODE PARAM_VALUE.OUTPUT_COLOR_MODE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.OUTPUT_COLOR_MODE}] ${MODELPARAM_VALUE.OUTPUT_COLOR_MODE}
}

proc update_MODELPARAM_VALUE.COLORIMETRY { MODELPARAM_VALUE.COLORIMETRY PARAM_VALUE.COLORIMETRY } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.COLORIMETRY}] ${MODELPARAM_VALUE.COLORIMETRY}
}

proc update_MODELPARAM_VALUE.YCC_RANGE { MODELPARAM_VALUE.YCC_RANGE PARAM_VALUE.YCC_RANGE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.YCC_RANGE}] ${MODELPARAM_VALUE.YCC_RANGE}
}

proc update_MODELPARAM_VALUE.OUTPUT_COLOR_DEPTH { MODELPARAM_VALUE.OUTPUT_COLOR_DEPTH PARAM_VALUE.OUTPUT_COLOR_DEPTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.OUTPUT_COLOR_DEPTH}] ${MODELPARAM_VALUE.OUTPUT_COLOR_DEPTH}
}

