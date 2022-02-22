classdef MagProController<handle
    %MAGPROCONTROLLER controls a MagVenture MagPro stimulator
    %
    % Usage, for a log file with an UUID name on current folder:
    %   device=MAGPROCONTROLLER('serial port device name')
    % Or, to name the logfile as desired:
    %   device=MAGPROCONTROLLER('serial port device name','logfile.txt')
    %
    % To free the serial port for other use, simply
    %   delete(device);
    %
    %   Connect a serial port cable to the 'COM2' port of the stimulator.
    %
    %   The class has been tested on MATLAB R2017b & R2021a, and with a
    %   MagPro R30 incl. MagOption. The routines are written for near
    %   'vanilla' MATLAB. They require 'Instrument Control Toolbox', but I
    %   cannot guarantee that no additional MATLAB's internal toolboxes are
    %   needed.
    %
    %   The MagPro device sends also other data that is not described in
    %   its user guide, but as far as I can tell this data adheres to the
    %   same package format. Any such data is logged by the class, but not
    %   processed futher. Such data mostly occurs when a device is powered
    %   on, or coil is removed, or other rare events occur.
    %
    %   This is missing commands 9 (set & get for general pulse settings).
    %   To implement and test this, I need access to X100 incl. MagOption, 
    %   as I will need to test that the settings work correctly.
    %
    %   This program is distributed WITHOUT ANY WARRANTY, not even implied
    %   warranty of any sort.
    %
    % Author Lari Koponen
    % Version 20210419
    
    properties(SetAccess=private)
        % A logfile
        logfilename
        % A list of TMS pulses (a subset of logfile)
        pulselist=struct('clock',[],'amplitude',uint8(255),'didt',uint8(255),'mode',uint8(255),'waveform',uint8(255));
        pulselist_index=0;
        % Current device amplitudes
        amplitudes=uint8([0 0]);
        % Current coil temperature and coil type
        coil_temperature_and_type=uint8([0 0]);
    end
    
    properties(Access=private)
		% Interface for serial port (0 = serialport, 1 = serial)
		olderThanR2019b
        % A serial port object
        serialport
        % An internal serial port buffer
        buffer=uint8([]);
        % A logfile
        logfile
        % A state variable for interpretation of triggers from twin/dual
        isPP=false;
    end

    methods
        function obj=MagProController(serialportname,varargin)
            %MAGPROLISTENER Construct an instance of MagProListener
            %
            %   This will reserve a serial port device for the class.
            %
            % Author Lari Koponen
            % Version 20210416
            
            % Validate user input
            assert(nargin>0,'Provide ''serialport'' as an input argument.');
            assert(ischar(serialportname),'Provided ''serialport'' must be a string.');
            
            % List available serial portss, and check for the provided port
            out=instrhwinfo('serial');
            serialports=out.AvailableSerialPorts;            
            assert(any(strcmp(serialports,serialportname)),'Provided ''serialport'' does not exists or is in use.');
            
			obj.olderThanR2019b=verLessThan('matlab','9.7');
			
			if obj.olderThanR2019b
				obj.serialport=serial(serialportname);
				obj.serialport.BaudRate=38400;
				obj.serialport.BytesAvailableFcnCount=8;
				obj.serialport.BytesAvailableFcnMode='byte';
				obj.serialport.BytesAvailableFcn={@(src,evt) obj.callback(src,evt)};        
				fopen(obj.serialport);
			else
				obj.serialport=serialport(serialportname,38400);
				configureCallback(obj.serialport,'byte',8,@(src,evt) obj.callback(src,evt));
			end
            
            if nargin==1
                obj.logfilename=[tempname('.') '.txt'];
            else
                obj.logfilename=varargin{1};
            end
            obj.logfile=fopen(obj.logfilename,'a');
            disp(['Appending log to ''' obj.logfilename '''.']);
            
            str='Time                   	Raw data	Interpreted message (type SO(A) SO(B) di/dt(A) di/dt(B) temperature coiltype mode waveform)\n';
            % Write to logfile
            fprintf(obj.logfile,str);
        end
        
        function delete(obj)
            %DELETE destroys the MagProListener controlledly
            %
            %   This will free the serial port device for other use.
            %
            % Author Lari Koponen
            % Version 20210416
            
            if ~isempty(obj.logfile)
                fclose(obj.logfile);
            end
            
            if obj.olderThanR2019b
				fclose(obj.serialport);
            else
                delete(obj.serialport);
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
            % Author Lari Koponen
            % Version 20210416
            
            % The command 1 sets amplitudes:
            command=1;
            
            assert(~isempty(amplitudes),'Give a list of 1 or 2 amplitudes.');
            switch length(amplitudes)
                case 1
                    A=amplitudes(1);
                    assert(mod(A,1)==0&&A>=0&&A<=100,'Amplitude A must be an integer between 0 and 100.');
                    message=uint8([command;A]);
                case 2
                    A=amplitudes(1);
                    assert(mod(A,1)==0&&A>=0&&A<=100,'Amplitude A must be an integer between 0 and 100.');
                    B=amplitudes(2);
                    assert(mod(B,1)==0&&B>=0&&B<=100,'Amplitude B must be an integer between 0 and 100.');
                    message=uint8([command;A;B]);
                otherwise
                    return
            end
            obj.send(message);
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
            % Version 20210416
            
            % The command 2 sets the device status (enabled/disabled):
            command=2;
            
            assert(~isempty(status),'You must give the new status (0/1).');
            switch status(1)
                case 0
                    message=uint8([command;0]);
                case 1
                    message=uint8([command;1]);
                otherwise
                    return
            end
            obj.send(message);
        end
        
        function trigger(obj)
            %TRIGGER triggers a TMS pulse
            %
            %   The pulse is only triggered if device is in enabled status.
            %
            %   See also SETSTATUS, START
            %
            % Author Lari Koponen
            % Version 20210416
            
            % The command 3 is trigger:
            command=3;
            
            obj.send(uint8(command));
        end
        
        function start(obj)
            %START starts a TMS pulse train
            %
            %   The pulse train is only triggered if device is in enabled
            %   and in the 'Timing' page. The pulse trains can be started
            %   even if timing control is 'External Trig' and not changed
            %   to 'Sequence'.
            %
            %   See also SETSTATUS, SETPAGE, TRIGGER
            %
            % Author Lari Koponen
            % Version 20210416
            
            % The command 4 is to start a pulse train:
            command=4;
            
            obj.send(uint8(command));
        end
        
        function getParameters(obj)
            %GETPARAMETERS asks the device for its settings
            %
            %   I do not have a parser for the response 5, yet.
            %
            % Author Lari Koponen
            % Version 20210416
            
            % The command 5 results in response 5, 15 bytes:
            command=5;
            
            obj.send(uint8(command));
        end
        
        function setTiming(obj,RR,PiR,NoT,ITI)
            %SETTIMING sets parameters for a pulse train
            %
            % Usage:
            % SETTIMING(rep. rate, pulses in train, number of trains, ITI)
            %
            %   The pulse train parameters can be changed only if device is
            %   in the 'Timing' page.
            %
            %   Closest allowed repetition rate / ITI is selected, this may
            %   differ from the requested value, as beyond 1 Hz RR must be
            %   an integer, and as ITI must be a multiple of 0.1 s.
            %
            %   See also SETSTATUS, SETPAGE, START
            %
            % Author Lari Koponen
            % Version 20210416
            
            % The command 6 sets pulse train parameters:
            command=6;
            
            % Assume X100, and all its possible repetition rates
            %
            % This allows rates up to 100 Hz
            % With MagOption in twin/dual mode the limit is 20 Hz
            %
            % For R30, the limit is 30 Hz
            % With MagOption, the limit is 5 Hz
            RR=round(10*RR);
            assert(ismember(RR,[1:9 10:10:1000]),'Incorrect repetition rate.');
            
            % For all MagPro devices, same limits apply:
            assert(mod(PiR,1)==0&&PiR>=1&&PiR<=1000,'Pulses in train must be 1..1000.');
            assert(mod(NoT,1)==0&&NoT>=1&&NoT<=500,'Number of trains must be 1..500.');
            ITI=round(10*ITI);
            assert(ITI>=1&&ITI<=1200,'Inter-train interval must be between 0.1 and 120 s.');
            
            message=[
                command ...
                fliplr(typecast(uint16(RR),'uint8')) ...
                fliplr(typecast(uint16(PiR),'uint8')) ...
                fliplr(typecast(uint16(NoT),'uint8')) ...
                fliplr(typecast(uint16(ITI),'uint8')) ...
                ]';
            
            obj.send(uint8(message));
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
            % Version 20210416
            
            % The command 7 sets the page:
            command=7;
            
            assert(ischar(page),'You must define a page as a string.');
            switch page
                case 'Main'
                    ID=1;
                case 'Timing'
                    ID=2;
                case 'Trigger'
                    ID=3;
                case 'Configure'
                    ID=4;
                case 'Protocol'
                    ID=7;
                otherwise
                    return
            end
          
            obj.send(uint8([command;ID;0]));
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
            % Author Lari Koponen
            % Version 20210419
            
            % The command 8 sets the delays:
            command=8;
                        
            % Input trigger delay must be 0, 0.1, 0.2, ..., 1, 2, 100 ms
            delayTrigInput=round(10*delayTrigInput);
            assert(ismember(delayTrigInput,[0:9 10:10:1000]),'Incorrect input trigger delay.');
            
            % Output trigger delay must be:
            % -100, -99, -98, ... -10.0, -9.9, -9.8, ..., 10.0, 11, 100 ms
            delayTrigOutput=round(10*delayTrigOutput);
            assert(ismember(delayTrigInput,[-1000:10:-100 -99:99 100:10:1000]),'Incorrect output trigger delay.');
            
            % Charge delay must be:
            % 0, 10, 20, ..., 100, 200, 300, ..., 1000, 2000, 3000, 10000 ms
            assert(ismember(delayCharge,[0:10:90 100:100:900 1000:1000:10000]),'Incorrect charge delay.');
       
            message=[
                command ...
                fliplr(typecast(uint16(delayTrigInput),'uint8')) ...
                fliplr(typecast(int16(delayTrigOutput),'uint8')) ...
                fliplr(typecast(uint16(delayCharge),'uint8')) ...
                0 0 ...
                ]';
            
            obj.send(uint8(message));
        end
    end
    
    methods(Access=private)
        function callback(obj,src,evt)
            %CALLBACK processes incoming data from the device
            %
            %   The functions first reads new data (if any), and appends
            %   that into the class's internal buffer. Then, if there is
            %   sufficient amount of data, the data is parsed. Otherwise
            %   the function returns (which, essentially, waits for more
            %   data to be received).
            %
            %   Note that the check for having a non-zero amount of data
            %   available is necessary, as an earlier call to this routine
            %   might have already read the data which triggered the latest
            %   callback event.
            %
            %   Each callback processed 0-N events from the buffer.
            %
            % Author Lari Koponen
            % Version 2021-04-19
  
            if obj.olderThanR2019b
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
                        if obj.olderThanR2019b
                            abstime=evt.Data.AbsTime;
                        else
                            abstime=evt.AbsTime;
                        end
                        timestr=datestr(abstime,'yyyy-mm-dd HH:MM:SS.FFF');
                        result=MagProController.parseMessage(magpro_body);
                        %
                        
                        switch result(1)
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
                        end

                        %                        
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
            % Version 2021-04-16
            magpro_startflag=254;
            magpro_length=length(message);
            magpro_CRC8=MagProController.CRC(message,0);
            magpro_endflag=255;
            
            packet=[magpro_startflag;magpro_length;message;magpro_CRC8;magpro_endflag];
            
            if obj.olderThanR2019b
                fwrite(obj.serialport,packet);
            else
                write(obj.serialport,packet,'uint8');
            end
        end
    end
    
    methods(Access=private,Static)
        function result=parseMessage(message)
            %PARSEMESSAGE parses the outputof COM2 of MagVenture MagPro devices
            %
            %   Based on user guide, page 26.
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
            % Codex of known coil type (numbers):
            %    0 = 'Unknown' (tested, any coil without auxiliary connector)
            %   72 = 'C-B60' (from the documentation)
            %   82 = 'MC-B70' (tested)
            %
            % Author Lari Koponen
            % Version 2021-04-15
            
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

            switch message(1)
                case {1 2 3}
                    result(8)=bitand(message(4),3);
                    result(9)=bitand(message(4),12)/4;
            end
        end
        
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
            % Version 2021-04-16
            
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
    end
end
