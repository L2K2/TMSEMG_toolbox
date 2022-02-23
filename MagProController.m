classdef MagProController<handle
    %MAGPROCONTROLLER controls a MagVenture MagPro stimulator
    %
    % Connect a regular serial cable between a serial port on the computer
    % and the port 'COM2' of the MagVenture MagPro TMS device.
    %
    % Usage, for a log file with an UUID name on current folder:
    %   device=MAGVENTUREMAGPRO('serial port device')
    % Or, to name the log file as desired:
    %   device=MAGVENTUREMAGPRO('serial port device','log.txt')
    %
    % For example, when using the first serial port on the motherboard:
    %   device=MAGVENTUREMAGPRO('COM1')
    %
    % To free the serial port for other use, simply call:
    %   delete(device)
    %
    % Delete is also implisitly called when the handle to class is lost,
    % for example, with command 'clear'.
    %
    % The MagPro devices send also other data that is not described in
    % its user guide, but as far as I can tell this data adheres to the
    % same package format. Any such data is logged by the class, but not all
    % data is processed beyond logging. Some examples of such data occurs
    % when a device is powered on, or a coil is removed, or other similar
    % atypical events occur. The raw events are stored for later analysis.
    %
    % This program is distributed WITHOUT ANY WARRANTY, not even implied
    % warranty of any sort.
    %
    % Author Lari Koponen
    % Version 20220223
    
    %% Visible member variables (read-only from the outside)
    
    properties(SetAccess=private)
        % Name of current logfile
        logfilename
        % A list of observed TMS pulses (for TMS-EMG toolbox UI)
        pulselist=struct('clock',[],'amplitude',uint8(255),'didt',uint8(255),'mode',uint8(255),'waveform',uint8(255));
        pulselist_index=0;
        % Current device amplitudes
        amplitudes=uint8([0 0]);
        % Current coil temperature and coil type
        coil_temperature_and_type=uint8([0 0]);
    end
    
    %% Internal member variables
    
    properties(Access=private)
		% Interface version for serial port (0 = serialport, 1 = serial)
		isOlderThanR2019b
        % A serial port object
        serialport
        % An internal data buffer for serial data
        buffer=uint8([]);
        % A logfile handle
        logfile
        % A state variable for interpretation of triggers from twin/dual
        isPP=false;
        % Device response ID 0, provoked with query 0; subset of ID 5
        statusShort
        receivedStatusShort=false;
        % Device response ID 5, provoked with query 5
        statusLong
        receivedStatusLong=false;
        % Device response ID 9, provoked with query 9
        waveform
        receivedWaveform=false;
    end

    %% Member methods
    
    methods
        function obj=MagProController(serialportname,varargin)
            %MAGPROCONTROLLER Construct an instance of MagProController
            %
            % This will reserve a serial port device for the class.
            %
            % Author Lari Koponen
            % Version 20210223
            
            % Validate user input
            assert(nargin>0,'Provide ''serialport'' as an input argument.');
            assert(ischar(serialportname),'Provided ''serialport'' must be a string.');
            
            % List available serial ports, and check for the provided port
            out=instrhwinfo('serial');
            serialports=out.AvailableSerialPorts;
            assert(any(strcmp(serialports,serialportname)),'Serial port named ''%s'' does not exists or it is already in use.',serialportname);
            
            % Check MATLAB version
			obj.isOlderThanR2019b=verLessThan('matlab','9.7');
            
            % Select appropriate serial port interface based on version
			if obj.isOlderThanR2019b
				obj.serialport=serial(serialportname);
				obj.serialport.BaudRate=38400;
				obj.serialport.BytesAvailableFcnCount=4;
				obj.serialport.BytesAvailableFcnMode='byte';
				obj.serialport.BytesAvailableFcn={@(src,evt) obj.callback(src,evt)};        
				fopen(obj.serialport);
			else
				obj.serialport=serialport(serialportname,38400);
				configureCallback(obj.serialport,'byte',4,@(src,evt) obj.callback(src,evt));
			end
            
            if nargin==1
                obj.logfilename=[tempname('.') '.txt'];
            else
                obj.logfilename=varargin{1};
            end
            obj.logfile=fopen(obj.logfilename,'a');
            
            % Write header to logfile
            fprintf(obj.logfile,'Time                   	Raw data	Interpreted message (type SO(A) SO(B) di/dt(A) di/dt(B) temperature coiltype mode waveform)\n');
        end
        
        function delete(obj)
            %DELETE destroys the controller instance controlledly
            %
            % This will free the serial port device for other use.
            %
            % Author Lari Koponen
            % Version 20210514
            
            if ~isempty(obj.logfile)
                fclose(obj.logfile);
            end
            
            if obj.isOlderThanR2019b
				fclose(obj.serialport);
            else
                delete(obj.serialport);
            end
        end
        
        function status=getStatus(obj)
            %GETSTATUS asks the device for its short status
            %
            %   See also GETPARAMETERS
            %
            % Author Lari Koponen
            % Version 20210514
            
            token=tic();
            obj.receivedStatusShort=false;
            
            % The command 0 results in response 0, 9 bytes:            
            obj.send(0);
            
            % Wait for at most 1 second for the device, probe every 20 ms,
            % the device typically responds in 20-80 ms.
            while 1
                pause(0.02);
                if obj.receivedStatusShort
                    status=MagProController.parseMessage0(obj.statusShort);
                    break
                end
                assert(toc(token)<1,'Failed to receive short status message from the device in one second.');
            end
        end
        
        function setAmplitude(obj,amplitudes)
            %SETAMPLITUDE sets the stimulator output
            %
            % Usage:
            %   SETAMPLITUDE(A)
            % Or:
            %   SETAMPLITUDE([A B])
            % Where A and B are integers between 0 and 100.
            %
            % Other numbers are rounded to neareast allowed value.
            %
            % Author Lari Koponen
            % Version 20220222
            
            % Validate and correct user input:
            switch numel(amplitudes)
                case 1
                    A=MagProController.nearestAllowedValue(amplitudes(1),0:100);
                    B=0;
                case 2
                    A=MagProController.nearestAllowedValue(amplitudes(1),0:100);
                    B=MagProController.nearestAllowedValue(amplitudes(2),0:100);
                otherwise
                    error('Please provide a list of 1 or 2 amplitude values.');
            end
            
            % The command 1 sets amplitudes:
            obj.send([1;A;B]);
        end
        
        function setStatus(obj,status)
            %SETSTATUS enables or disables the stimulator
            %
            % Usage to enable the stimulatoe:
            %   SETSTATUS(1)
            % Or, to disable:
            %   SETSTATUS(0)
            %
            % Author Lari Koponen
            % Version 20220222
            
            assert(~isempty(status),'Please provide a new status.');
            switch status(1)
                case {0,1}
                    % The command 2 sets the device status (enabled/disabled):
                    obj.send([2;status(1)]);
                otherwise
                    error('The provided status must be either 0 or 1.');
            end
        end
        
        function enable(obj)
            %ENABLE enables the TMS device
            %
            %   See also DISABLE, SETSTATUS
            %
            % Author Lari Koponen
            % Version 20210416
            
            obj.setStatus(1);
        end
        
        function disable(obj)
            %DISABLE disables the TMS device
            %
            %   See also ENABLE, SETSTATUS
            %
            % Author Lari Koponen
            % Version 20210416
            
            obj.setStatus(0);
        end
        
        function trigger(obj)
            %TRIGGER triggers a TMS pulse
            %
            %   The pulse is only triggered if device is in enabled status.
            %
            %   See also ENABLE, START
            %
            % Author Lari Koponen
            % Version 20210416
            
            % The command 3 is trigger:
            obj.send(3);
        end
        
        function start(obj)
            %START starts a TMS pulse train
            %
            %   The pulse train is only triggered if device is in enabled
            %   and in the 'Timing' page. The pulse trains can be started
            %   even if timing control is 'External Trig' and not changed
            %   to 'Sequence'.
            %
            %   See also ENABLE, SETPAGE, TRIGGER
            %
            % Author Lari Koponen
            % Version 20210416
            
            % The command 4 is to start a pulse train:
            obj.send(4);
        end
        
        function status=getParameters(obj)
            %GETPARAMETERS asks the device for its settings
            %
            %   See also GETSTATUS
            %
            % Author Lari Koponen
            % Version 20210513
            
            token=tic();
            obj.receivedStatusLong=false;
            
            % The command 5 results in response 5, 15 bytes:            
            obj.send(5);
            
            % Wait for at most 1 second for the device, probe every 20 ms,
            % the device typically responds in 20-80 ms.
            while 1
                pause(0.02);
                if obj.receivedStatusLong
                    status=MagProController.parseMessage5(obj.statusLong);
                    break
                end
                assert(toc(token)<1,'Failed to receive full status message from the device in one second.');
            end
        end
        
        function setTiming(obj,RR,PiR,NoT,ITI)
            %SETTIMING sets parameters for a pulse train
            %
            % Usage:
            % SETTIMING(rep. rate, pulses in train, number of trains, ITI)
            %
            % The pulse train parameters can be changed only if device is
            % in the 'Timing' page.
            %
            % Closest allowed values are selected.
            %   Rep. rate must be: 0.1, 0.2, ..., 1.0, 2, 3, ..., 100 Hz
            %   Pulses in train must be: 1, 2, ..., 1000
            %   Number of trains: 1, 2, ..., 500
            %   ITI must be: 0.1, 0.2, ... 120.0 s
            %
            % The pulse train parameters are validated with with assumption
            % of an X100 in standard mode. This affects the range of valid
            % repetition rates (to 100 Hz).
            %
            % The device will refuse some values if it is not an X100, or
            % if it is an X100 in specific modes. For example, an X100 with
            % Magoption in either twin or dual mode will only go to 20 Hz;
            % an R30 will only go to 30 Hz; and an R30 with MagOption in
            % twin or dual mode will only go to 5 Hz.
            %
            %   See also SETSTATUS, SETPAGE, START
            %
            % Author Lari Koponen
            % Version 20220222
            
            % Select nearest valid repetition rate, correct for X100:
            assert(isnumeric(RR),'Repetition rate must be a number.'); % For the multiplication, MATLAB otherwise might do implicit typecast.
            RR=MagProController.nearestAllowedValue(10*RR,[1:9 10:10:1000]);
            
            % For all MagPro devices, same limits apply:
            PiR=MagProController.nearestAllowedValue(PiR,1:1000);
            NoT=MagProController.nearestAllowedValue(NoT,1:500);
            assert(isnumeric(ITI),'ITI must be a number.'); % For the multiplication, MATLAB otherwise might do implicit typecast.
            ITI=MagProController.nearestAllowedValue(10*ITI,1:1200);
            
            % The command 6 sets pulse train parameters:            
            obj.send([
                6 ...
                fliplr(typecast(uint16(RR),'uint8')) ...
                fliplr(typecast(uint16(PiR),'uint8')) ...
                fliplr(typecast(uint16(NoT),'uint8')) ...
                fliplr(typecast(uint16(ITI),'uint8')) ...
                ].');
        end
        
        function setPage(obj,page)
            %SETPAGE sets which page is shown in the device UI
            %
            % Usage:
            %   SETPAGE(page)
            % Supported values for pages are:
            %   'Main', 'Timing', 'Trigger', 'Configure', and 'Protocol'
            %
            % Author Lari Koponen
            % Version 20220222
            
            % The command 7 sets the page:      
            obj.send([7;MagProController.pageNumber(page);0]);
        end
        
        function setTrigger(obj,delayTrigInput,delayTrigOutput,delayCharge)
            %SETTRIGGER sets trigger and charge delay parameters
            %
            % Usage:
            %   SETTRIGGER(input delay, output delay, charge delay)
            %
            % The input delay must be:
            %   0, 0.1, 0.2, ..., 1, 2, 3, ... 100 ms
            % The output delay must be:
            %   -100, -99, -98, ..., -10.0, -9.9, -9.8, ..., 10.0, 11, 12, ... 100 ms
            % The charge delay must be:
            %   0, 10, 20, ..., 100, 200, 300, ..., 1000, 2000, 3000, ..., 10000 ms
            %
            % Note that negative values for output delay are only possible
            % when the device timing is in the 'Sequence' mode (internal
            % trigger generation, i.e., no external trigger input).
            % Otherwise, the device will clamp this value to zero.
            %
            % Closest allowed value will be selected.
            %
            % Author Lari Koponen
            % Version 20220222
                                    
            % Input trigger delay must be 0, 0.1, 0.2, ..., 1, 2, 100 ms
            assert(isnumeric(delayTrigInput),'Input delay must be a number.'); % For the multiplication, MATLAB otherwise might do implicit typecast.
            delayTrigInput=MagProController.nearestAllowedValue(10*delayTrigInput,[0:9 10:10:1000]);
            
            % Output trigger delay must be:
            % -100, -99, -98, ... -10.0, -9.9, -9.8, ..., 10.0, 11, 100 ms
            assert(isnumeric(delayTrigOutput),'Output delay must be a number.'); % For the multiplication, MATLAB otherwise might do implicit typecast.
            delayTrigOutput=MagProController.nearestAllowedValue(10*delayTrigOutput,[-1000:10:-100 -99:99 100:10:1000]);
            
            % Charge delay must be:
            % 0, 10, 20, ..., 100, 200, 300, ..., 1000, 2000, 3000, 10000 ms
            delayCharge=MagProController.nearestAllowedValue(delayCharge,[0:10:90 100:100:900 1000:1000:10000]);
       
            % The command 8 sets the delays:
            obj.send([
                8 ...
                fliplr(typecast(uint16(delayTrigInput),'uint8')) ...
                fliplr(typecast(int16(delayTrigOutput),'uint8')) ...
                fliplr(typecast(uint16(delayCharge),'uint8')) ...
                0 0 ...
                ].');
        end
                
        function waveform=getWaveform(obj)
            %GETWAVEFORM asks the device for the settings on 'Main' page
            %
            % Author Lari Koponen
            % Version 20210513
            
            token=tic();
            obj.receivedWaveform=false;
            
            % The command 9 results in response 5, 15 bytes:            
            obj.send([9;0]);
            
            % Wait for at most 1 second for the device, probe every 20 ms,
            % the device typically responds in 20-80 ms.
            while 1
                pause(0.02);
                if obj.receivedWaveform
                    waveform=MagProController.parseMessage9(obj.waveform);
                    break
                end
                assert(toc(token)<1,'Failed to receive the waveform information from the device.');
            end
        end
        
        function setWaveform(obj,varargin)
            %SETWAVEFORM sets pulse waveform
            %
            % Usage:
            %   SETWAVEFORM('name',value, ...)
            %
            % Name-value pairs are:
            %   'Mode': {'Standard','Power','Twin','Dual'}
            %   'CurrentDirection': {'Normal','Reverse'}
            %   'Waveform': {'Monophasic','Biphasic','Halfsine','Biphasic Burst'}
            %   'BurstPulses': [2,3,4,5] (retain previous valid value)
            %   'InterPulseInterval': (see device manual, depends on mode, rounded to nearest allowed value for given mode)
            %   'Pulse_BA_Ratio': 0.20:0.05:5.00 (rounded to nearest allowed value)
            %
            % The supported values depend on your device.
            %
            % Author Lari Koponen
            % Version 20220222
            
            % Get current waveform, to modify it as instructed by the user:
            temp=obj.getWaveform();
            
            % Parse the user input with 'inputParser'
            parser=inputParser;
            addParameter(parser,'Mode',temp.modeString,@(x) any(strcmpi({'Standard','Power','Twin','Dual'},x)));
            addParameter(parser,'CurrentDirection',temp.currentDirectionString,@(x) any(strcmpi({'Normal','Reverse'},x)));
            addParameter(parser,'Waveform',temp.waveformString,@(x) any(strcmpi({'Monophasic','Biphasic','Halfsine','Biphasic Burst'},x)));
            addParameter(parser,'BurstPulses',0,@(x) any(x==2:5));
            addParameter(parser,'InterPulseInterval',-1,@(x) isnumeric(x));
            addParameter(parser,'Pulse_BA_Ratio',1,@(x) isnumeric(x));
            parse(parser,varargin{:});
            
            % Update 'Mode'
            mode=MagProController.modeNumber(parser.Results.Mode);   
            
            % Update 'Current Direction'
            currentDirection=MagProController.currentDirectionNumber(parser.Results.CurrentDirection);
            
            % Update 'Waveform'
            waveformIndex=MagProController.waveformNumber(parser.Results.Waveform);
            
            % Validate the mode-waveform pair
            assert(mode<2||waveformIndex<3,'Cannot set mode to either ''Twin'' or ''Dual'' with waveform ''Biphasis Burst''.');
            
            % Update number of pulses in a biphasic burst
            switch parser.Results.BurstPulses
                case 5
                    burstPulses=0;
                case 4
                    burstPulses=1;
                case 3
                    burstPulses=2;
                case 2
                    burstPulses=3;
                otherwise % Retain current setting
                    burstPulses=temp.burstPulses;
            end
            
            % Update 'Inter Pulse Interval'
            if parser.Results.InterPulseInterval<0
                tempIPI=10*temp.interPulseInterval;
            else
                tempIPI=10*parser.Results.InterPulseInterval;
            end
            if waveformIndex==3 % Biphasic Burst
                interPulseInterval=MagProController.nearestAllowedValue(tempIPI,[5:99 100:5:195 200:10:1000]);
            else
                interPulseInterval=MagProController.nearestAllowedValue(tempIPI,[10:99 100:5:195 200:10:990 1000:100:4900 5000:500:9500 10000:1000:30000]);
            end
            
            % Update 'Pulse B/A Ratio' if applicable
            if mode==2 % Twin
                valueSecondPulse=MagProController.nearestAllowedValue(100*parser.Results.Pulse_BA_Ratio,20:5:500);
            else
                valueSecondPulse=0;
            end
                        
            % The command 0901 sets the waveform:
            obj.send([
                9 1 ...
                temp.model ...
                mode currentDirection waveformIndex burstPulses ...
                fliplr(typecast(uint16(interPulseInterval),'uint8')) ...
                fliplr(typecast(uint16(valueSecondPulse),'uint8'))...
                ].');
        end
    end
    
    %% Internal member methods
    
    methods(Access=private)
        function callback(obj,src,evt)
            %CALLBACK processes incoming data from the device
            %
            % The functions first reads new data (if any), and appends
            % that into the class's internal buffer. Then, if there is
            % sufficient amount of data, the data is parsed. Otherwise
            % the function returns (which, essentially, waits for more
            % data to be received).
            %
            % Note that the check for having a non-zero amount of data
            % available is necessary, as an earlier call to this routine
            % might have already read the data which triggered the latest
            % callback event.
            %
            % Each callback processes 0-N events from the buffer.
            %
            % Author Lari Koponen
            % Version 20220222
  
            if obj.isOlderThanR2019b
                if src.BytesAvailable>0
                    data=fread(src,src.BytesAvailable);
                    obj.buffer=[obj.buffer;data];
                end
            else
                if src.NumBytesAvailable>0
                    data=read(src,src.NumBytesAvailable,'uint8')';
                    obj.buffer=[obj.buffer;data];
                end
            end
            
            magpro_startflag=254;
            magpro_endflag=255;
            
            % Process all full messages from the buffer
            N=length(obj.buffer);
            while N>=4
                if obj.buffer(1)==magpro_startflag
                    magpro_length=obj.buffer(2);
                    if N>=4+magpro_length
                        magpro_body=obj.buffer(3:magpro_length+2);
                        magpro_CRC8=obj.buffer(magpro_length+3);
                        assert(obj.buffer(magpro_length+4)==magpro_endflag,'Data error, missing end flag from a message');
                        assert(MagProController.CRC(magpro_body,magpro_CRC8)==0,'The message CRC checksum does not match.');
                        
                        % A good message was received, remove from buffer
                        obj.buffer=obj.buffer(magpro_length+5:end);
                        N=length(obj.buffer);
                        % Process the message
                        if obj.isOlderThanR2019b
                            abstime=evt.Data.AbsTime;
                        else
                            abstime=evt.AbsTime;
                        end
                        timestr=datestr(abstime,'yyyy-mm-dd HH:MM:SS.FFF');
                        result=MagProController.parseMessage(magpro_body);
                        
                        switch result(1)
                            case 0% Receive short status
                                obj.statusShort=magpro_body;
                                obj.receivedStatusShort=true;
                            case 1 % Update device amplitude information
                                obj.amplitudes=result(2:3);
                            case 2 % Receive information about a TMS pulse
                                % Update pulse list
                                % (Not working for twin/dual modes):
                                % in these modes, some pulse return one
                                % pulse events some two events, depending
                                % on the ISI among other things. This
                                % causes ambiguity if amplitude B is zero.
                                if result(8)<2 % a single pulse mode
                                    obj.pulselist_index=obj.pulselist_index+1;
                                    obj.pulselist(obj.pulselist_index).clock=abstime;
                                    obj.pulselist(obj.pulselist_index).amplitude=obj.amplitudes(1);
                                    obj.pulselist(obj.pulselist_index).didt=result(4);
                                    obj.pulselist(obj.pulselist_index).mode=result(8);
                                    obj.pulselist(obj.pulselist_index).waveform=result(9);
                                else % a twin/dual pulse mode
                                    % We can receive either one or two
                                    % events for a single trigger of twin
                                    % or dual pulse. This depends on the
                                    % ISI between the two pulses, and the
                                    % cutoff is not defined in user manual.
                                    
                                    if obj.isPP % We already recorded the first pulse
                                        % Reset state, save second pulse
                                        obj.isPP=false;
                                        obj.pulselist_index=obj.pulselist_index+1;
                                        obj.pulselist(obj.pulselist_index).clock=abstime;
                                        obj.pulselist(obj.pulselist_index).amplitude=obj.amplitudes(2);
                                        obj.pulselist(obj.pulselist_index).didt=result(5);
                                        obj.pulselist(obj.pulselist_index).mode=result(8);
                                        obj.pulselist(obj.pulselist_index).waveform=result(9);
                                    else % We have not seen a first pulse yet
                                        obj.pulselist_index=obj.pulselist_index+1;
                                        obj.pulselist(obj.pulselist_index).clock=abstime;
                                        obj.pulselist(obj.pulselist_index).amplitude=obj.amplitudes(1);
                                        obj.pulselist(obj.pulselist_index).didt=result(4);
                                        obj.pulselist(obj.pulselist_index).mode=result(8);
                                        obj.pulselist(obj.pulselist_index).waveform=result(9);
                                        if result(5)==0
                                            % The second pulse di/dt was zero
                                            %
                                            % This breaks if second pulse
                                            % really has zero intensity.
                                            % This, however, cannot be
                                            % fixed by checking the
                                            % amplitude, as the device does
                                            % not necessarily report the
                                            % amplitudes before we get the
                                            % pulse!
                                            obj.isPP=true;
                                        else
                                            obj.pulselist_index=obj.pulselist_index+1;
                                            obj.pulselist(obj.pulselist_index).clock=abstime;
                                            obj.pulselist(obj.pulselist_index).amplitude=obj.amplitudes(2);
                                            obj.pulselist(obj.pulselist_index).didt=result(5);
                                            obj.pulselist(obj.pulselist_index).mode=result(8);
                                            obj.pulselist(obj.pulselist_index).waveform=result(9);
                                        end
                                    end
                                end
                            case 3 % Receive information about temperature and coil type
                                obj.coil_temperature_and_type=result(6:7);
                            case 5 % Receive long status
                                obj.statusLong=magpro_body;
                                obj.receivedStatusLong=true;
                            case 9 % Receive information on pulse waveform
                                obj.waveform=magpro_body;
                                obj.receivedWaveform=true;
                        end

                        % Write event to string              
                        str=sprintf('%s\t%s\t%s\n', ...
                            timestr, ...
                            sprintf('%.2X',magpro_body), ...
                            sprintf('%d\t',result));
                        % Write to logfile
                        fprintf(obj.logfile,str);
                    else
                        return
                    end
                else
                    % The buffer does not start with a start flag,
                    % discard first byte
                    obj.buffer=obj.buffer(2:end);
                    N=length(obj.buffer);
                end
            end
        end
        
        function send(obj,message)
            %SEND sends a command to the device
            %
            % Author Lari Koponen
            % Version 20210416
            
            magpro_startflag=254;
            magpro_length=length(message);
            magpro_CRC8=MagProController.CRC(message,0);
            magpro_endflag=255;
            
            packet=[magpro_startflag;magpro_length;message;magpro_CRC8;magpro_endflag];
                        
            if obj.isOlderThanR2019b
                fwrite(obj.serialport,packet);
            else
                write(obj.serialport,packet,'uint8');
            end
        end
    end
    
    %% Internal static methods
    
    methods(Access=private,Static)
        function CRC8=CRC(message,CRC8)
            %CRC computes Dallas/Maxim checksum
            %
            % To compute the checksum:
            %   checksum=CRC(message,0)
            %
            % And, to check a message, check that:
            %   CRC(message,checksum)==0
            %
            % Author Lari Koponen
            % Version 20210416
            
            % Bitmask, for LSB
            persistent mask
            if isempty(mask)
                mask=uint8([
                     1
                     2
                     4
                     8
                    16
                    32
                    64
                   128
               ]);
            end

            % Dallas/Maxim polynomial: X^8 + X^5 + X^4 + 1, rotated
            persistent polynomial
            if isempty(polynomial)
                polynomial=uint8([
                    25     1
                    50     2
                   100     4
                   200     8
                   144    17
                    32    35
                    64    70
                   128   140
                ]);
            end

            tmp=uint8([message;CRC8]);
            
            % Compute cyclic redundancy check
            for i=1:length(message)
                for j=1:8
                    if bitand(tmp(i),mask(j))
                        tmp(i  )=bitxor(tmp(i  ),polynomial(j,1));
                        tmp(i+1)=bitxor(tmp(i+1),polynomial(j,2));
                    end
                end
            end

            % The checksum is the last byte of the padded message
            CRC8=tmp(end);
        end
        
        function y=nearestAllowedValue(x,allowedValues)
            %NEARESTALLOWEDVALUE returns the nearest allowed value
            %
            % Usage:
            %   NEARESTALLOWEDVALUE(value, allowedValues)
            % Where:
            %   value is the user input
            % And:
            %   allowedValues must be a sorted list of numbers
            %
            % Notably, the MATLAB-ish approach with
            %   y=interp1(allowedValues,allowedValies,x,'nearest','extrap');
            % seems to always round up, which is incorrect for negative x.
            %
            % Author Lari Koponen
            % Version 20220222

            assert(isnumeric(x),'x must be numeric.');
            
            assert(isnumeric(allowedValues)&&isvector(allowedValues)&&issorted(allowedValues),'Allowed values must be a sorted vector.');

            % Find first larger element:
            index=find(x<=allowedValues,1);

            % If none, x is larger than any allowed value, return last value:
            if isempty(index)
                y=allowedValues(end);
                return
            end

            % Correct rounding:
            if index>1
                previous=x-allowedValues(index-1);
                next=allowedValues(index)-x;
                if (next>previous)||((x<0)&&(next==previous))
                    index=index-1;
                end
            end
            y=allowedValues(index);
        end
        
        function result=parseMessage(message)
            %PARSEMESSAGE parses the outputof COM2 of MagVenture MagPro devices
            %
            % Based on MagVenture MagPro user guide, page 26.
            %
            % Each result is a non-negative integer,
            %   value -1 means that the result was not included in the message.
            %
            % result(1) = message type (1-3: Amplitude, di/di, Temperature)
            % result(2) = stimulator output for pulse A (0-199, % MSO)
            % result(3) = stimulator output for pulse B (0-199, % MSO)
            % result(4) = di/dt for pulse A (0..199, MA/s)
            % result(5) = di/dt for pulse A (0..199, MA/s)
            % result(6) = coil temperature in Celsius (0..199, degrees)
            % result(7) = coil type as an integer (0..199, #)
            % result(8) = mode (0-3: Standard, Power, Twin, Dual)
            % result(9) = waveform (0-3: Monophasic, Biphasic, Halfsine, Biphasic Burst) 
            %
            % Author Lari Koponen
            % Version 20210415
            
            result=-ones(1,9);

            result(1)=message(1);
            
            switch message(1)
                case 1 % amplitude
                    result(2)=message(2);
                    result(3)=message(3);
                case 2 % di/dt
                    result(4)=message(2);
                    result(5)=message(3);
                case 3 % temperature
                    result(6)=message(2);
                    result(7)=message(3);   
            end

            % The bitmasks are presented in base 10 as earlier MATLAB versions do not support either 0x or 0b prefix.
            %
            %   3 = 0b00000011
            %  12 = 0b00001100
            switch message(1)
                case {1 2 3}
                    result(8)=bitand(message(4),3);
                    result(9)=bitand(message(4),12)/4;
            end
        end
 
        function status=parseMessage0(message)
            %PARSEMESSAGE0 parses MagVenture MagPro message with event ID 0 (or 5)
            %
            %   This routine has been tested with a 'MagPro X100 incl. MagOption'.
            %   The test coverage was, for practical purposes 100%.
            %
            %   waveform=PARSEMESSAGE0(message)
            %
            % Author Lari Koponen
            % Version 20210514

            status=[];

            status.data=message;

            assert(length(message)>=9,'Message is too short');
            assert(message(1)==0||message(1)==5,'Message has incorrect ID.');

            % The bitmasks are presented in base 10 as earlier MATLAB versions do not support either 0x or 0b prefix.
            %
            %   3 = 0b00000011
            %  12 = 0b00001100
            %  16 = 0b00010000
            % 224 = 0b11100000
            status.mode=bitand(message(2),3);
            status.modeString=MagProController.modeString(status.mode);
            status.waveform=bitand(message(2),12)/4;
            status.waveformString=MagProController.waveformString(status.waveform);
            status.status=bitand(message(2),16)/16; % Enabled / Disabled
            status.model=bitand(message(2),224)/64;
            status.serialNumber=65536*uint32(message(3))+256*uint32(message(4))+uint32(message(5));
            status.temperature=message(6);
            status.coilTypeNumber=message(7);
            status.coilTypeString=MagProController.coilTypeString(status.coilTypeNumber);
            status.amplitudeA=message(8);
            status.amplitudeB=message(9);
        end

        function status=parseMessage5(message)
            %PARSEMESSAGE0 parses MagVenture MagPro message with event ID 0 (or 5)
            %
            %   This routine has been tested with a 'MagPro X100 incl. MagOption'.
            %   The test coverage was, for practical purposes 100%.
            %
            %   waveform=PARSEMESSAGE5(message)
            %
            % Author Lari Koponen
            % Version 20210514

            status=MagProController.parseMessage0(message);

            assert(length(message)>=15,'Message is too short');
            assert(message(1)==5,'Message has incorrect ID.');

            % The following relate to the amplitude ratios in the 'Protocol' page
            status.amplitudeA_setting=message(10);
            status.amplitudeB_setting=message(11);
            status.amplitudeA_factor=message(12)/100;
            status.amplitudeB_factor=message(13)/100;

            % We have the page number from the device
            status.pageNumber=message(14);
            status.pageString=MagProController.pageString(status.pageNumber);

            % Finally, we status of currently running 'Timing' or 'Protocol'
            status.ongoingPulseSequence=message(15);
        end

        function waveform=parseMessage9(message)
            %PARSEMESSAGE9 parses MagVenture MagPro message with event ID 9
            %
            %   This routine has been tested with a 'MagPro X100 incl. MagOption'.
            %   The test coverage was, for practical purposes 100%.
            %
            %   waveform=PARSEMESSAGE9(message)
            %
            % Author Lari Koponen
            % Version 20220222

            waveform=[];

            waveform.data=message;

            assert(length(message)==10,'Unexpected message length.');
            assert(message(1)==9,'Unexpected message ID.');
            assert(message(2)==0,'Unexpected value for second byte (read/write).');

            % Identify device model ID
            waveform.model=message(3);
            waveform.modelString=MagProController.modelString(message(3));

            % Identify pulse waveform setting
            waveform.mode=message(4);
            waveform.modeString=MagProController.modeString(message(4));

            % Identify current direction setting
            waveform.currentDirection=message(5);
            waveform.currentDirectionString=MagProController.currentDirectionString(message(5));

            % Identify pulse waveform
            waveform.waveform=message(6);
            waveform.waveformString=MagProController.waveformString(message(6));

            % Identify number of pulses in a 'Biphasic Burst' mode
            switch message(7)
                case 0
                    waveform.burstPulses=5;
                case 1
                    waveform.burstPulses=4;
                case 2
                    waveform.burstPulses=3;
                case 3
                    waveform.burstPulses=2;
                otherwise
                    error('Unknown number of pulses in a ''Biphasic Burst''.');
            end

            % Identify 'Inter Pulse Interval'
            %
            % The device provides the list index (starting from 0) of the selected
            % 'Inter Pulse Interval'. The list of possible values is different for
            % different modes. Thus, for 'X100+Option', the interpretation depends
            % on the current mode for the device. Other devices might have similar
            % quirks.
            if waveform.waveform==3 % Biphasic Burst (note that this 'waveform' prevents abovementioned 'mode' selection)
                interPulseIntervalTable=[1000:-10:200 195:-5:100 99:-1:5]/10;
                index=1+message(8);
                if index<=length(interPulseIntervalTable)
                    waveform.interPulseInterval=interPulseIntervalTable(index);
                else
                    waveform.interPulseInterval=nan;
                end
            else % Twin or Dual, or any other mode (for which, the value is meaningless)
                interPulseIntervalTable=[30000:-1000:10000 9500:-500:5000 4900:-100:1000 990:-10:200 195:-5:100 99:-1:10]/10;
                index=1+typecast(message([8 9]),'uint16');
                if index<=length(interPulseIntervalTable)
                    waveform.interPulseInterval=interPulseIntervalTable(index);
                else
                    waveform.interPulseInterval=nan;
                end
            end

            % Identify either 'Pulse B/A Ratio' or 'Pulse B Amplitude'
            %
            % As above, the interpretation of the message depends on the mode.
            %
            % Further, the interpretation depends on the previous value of mode.
            % That is, the device reports the value for latest 'Dual' or 'Twin'.
            if waveform.mode==2 % Twin
                pulse_BA_ratioTable=(500:-5:20)/100;
                index=1+message(10);
                if index<=length(pulse_BA_ratioTable)
                    waveform.pulse_BA_ratio=pulse_BA_ratioTable(index);
                else
                    waveform.pulse_BA_ratio=nan;
                end
                waveform.pulse_B_amplitude=nan;
            elseif waveform.mode==3 % Dual
                waveform.pulse_BA_ratio=nan;
                waveform.pulse_B_amplitude=100-message(10);
            else % For any other mode the values are meaningless   
                waveform.pulse_BA_ratio=nan;
                waveform.pulse_B_amplitude=nan;
            end
        end
    end
    
    %% External static methods, for conversion of data
    
    methods(Access=public,Static)
        function string=coilTypeString(number)
            %COILTYPESTRING converts 'coil type' number to string
            %
            % The list of known coils is a subset of available coils,
            % all listed coil numbers have been validated to be correct
            % for at least one MagPro device (of unknown software version).
            %
            % The text in brackets is added to better describe a coil
            % beyond the text shown on the MagPro device screen.
            %
            % Author Lari Koponen
            % Version 20220222

            assert(isnumeric(number),'Coil type must be a number.');
            
            switch number
                case 0
                    string='Unknown';
                case 56
                    string='Grp5-Coil [Cool-B35 HO]'; % at Duke University
                case 60
                    string='Cool-B65';
                case 64
                    string='Cool-B65 A/P';
                case 72
                    string='C-B60';
                case 81
                    string='MC-125';
                case 82
                    string='MC-B70';
                case 86
                    string='D-B80';
                otherwise
                    string=sprintf('[UNIDENTIFIED COIL NUMBER %d]',number);
            end
        end
        
        function number=currentDirectionNumber(string)
            %CURRENTDIRECTIONNUMBER converts string to number
            %
            % Possible values are 'Normal' and 'Reverse'.
            %
            % Author Lari Koponen
            % Version 20220222

            assert(ischar(string),'Current direction must be a string.');
            
            switch lower(string)
                case 'normal'
                    number=0;
                case 'reverse'
                    number=1;
                otherwise
                    error('Current direction ''%s'' is invalid.',string);
            end
        end
        
        function string=currentDirectionString(number)
            %CURRENTDIRECTIONSTRING converts number to string
            %
            % Author Lari Koponen
            % Version 20220222

            assert(isnumeric(number),'Current direction must be a number.');
            
            switch number
                case 0
                    string='Normal';
                case 1
                    string='Reverse';
                otherwise
                    string=sprintf('[UNKNOWN CURRENT DIRECTION %d]',number);
            end
        end

        function string=modelString(number)
            %MODELSTRING converts 'device model' number to string
            %
            % The list of known devices is based on 'MAGIC' toolbox.
            %
            % Author Lari Koponen
            % Version 20220222

            assert(isnumeric(number),'Model number must be a number.');
            
            switch number
                case 0
                    string='R30';
                case 1
                    string='X100';
                case 2
                    string='R30+Option';
                case 3
                    string='X100+Option';
                case 4
                    string='R30+Option+Mono';
                case 5
                    string='MST';
                otherwise
                    string=sprintf('[UNKNOWN MODEL %d]',number);
            end
        end
        
        function number=modeNumber(string)
            %MODENUMBER converts 'mode' string to number
            %
            % Possible values are 'Standard', 'Power', 'Twin' and 'Dual'.
            %
            % Author Lari Koponen
            % Version 20220222
            
            assert(ischar(string),'Mode name must be a string.');
            
            switch lower(string)
                case 'standard'
                    number=0;
                case 'power'
                    number=1;
                case 'twin'
                    number=2;
                case 'dual'
                    number=3;
                otherwise
                    error('Mode name ''%s'' is invalid.',string);
            end
        end
        
        function string=modeString(number)
            %MODESTRING converts 'mode' number to string
            %
            %   The mode number can be from 0 to 3 (two bits).
            %
            % Author Lari Koponen
            % Version 20220222

            assert(isnumeric(number),'Mode number must be a number.');
            
            switch number
                case 0
                    string='Standard';
                case 1
                    string='Power';
                case 2
                    string='Twin';
                case 3
                    string='Dual';
                otherwise
                    string=sprintf('[IMPOSSIBLE MODE NUMBER %d]',number);
            end
        end

        function number=pageNumber(string)
            %PAGENUMBER converts page name to its ID number
            %
            % Supported values for pages are:
            %   'Main', 'Timing', 'Trigger', 'Configure' and 'Protocol'
            %
            % This is because at least on the tested devices, one cannot set to pages:
            %   'Service' or 'Service2'
            %
            % Author Lari Koponen
            % Version 20220222

            assert(ischar(string),'Page name must be a string.');
            
            switch lower(string)
                case {'main','main menu (main)'}
                    number=1;
                case {'timing','timing menu (timing)'}
                    number=2;
                case {'trigger','trigger menu (trigger)'}
                    number=3;
                case {'configure','configuration menu (configure)'}
                    number=4;
                case {'protocol','protocol menu (protocol)'}
                    number=7;
                otherwise
                    error('Page name ''%s'' is invalid.',string);
            end
        end

        function string=pageString(number)
            %PAGESTRING converts 'page' number to string
            %
            % Author Lari Koponen
            % Version 20220222

            assert(isnumeric(number),'Page number must be a number.');
            
            switch number
                case 1
                    string='Main Menu (Main)';
                case 2
                    string='Timing Menu (Timing)';
                case 3
                    string='Trigger Menu (Trigger)';
                case 4
                    string='Configuration Menu (Configure)';
                case 7
                    string='Protocol Menu (Protocol)';
                case 13
                    string='Service Mode (Service)';
                case 17
                    string='Service Mode (Service2)';
                otherwise
                    string=sprintf('[UNKNOWN PAGE NUMBER %d]',number);
            end
        end

        function number=waveformNumber(string)
            %WAVEFORMNUMBER converts 'waveform' string to number
            %
            % Possible values are 'Monophasic', 'Biphasic', 'Halfsine' and 'Biphasic Burst'.
            %
            % Author Lari Koponen
            % Version 20220222

            assert(ischar(string),'Waveform name must be a string.');
            
            switch lower(string)
                case 'monophasic'
                    number=0;
                case 'biphasic'
                    number=1;
                case 'halfsine'
                    number=2;
                case 'biphasic burst'
                    number=3;
                otherwise
                    error('Waveform name ''%s'' is invalid.',string);
            end
        end

        function string=waveformString(number)
            %WAVEFORMSTRING converts 'waveform' number to string
            %
            %   The waveform number can be from 0 to 3 (two bits).
            %
            % Author Lari Koponen
            % Version 20220222

            assert(isnumeric(number),'Waveform number must be a number.');
            
            switch number
                case 0
                    string='Monophasic';
                case 1
                    string='Biphasic';
                case 2
                    string='Halfsine';
                case 3
                    string='Biphasic Burst';
                otherwise
                    string=sprintf('[IMPOSSIBLE WAVEFORM NUMBER %d]',number);
            end
        end
    end
end
