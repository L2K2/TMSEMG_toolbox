classdef TMSEMG_exported < matlab.apps.AppBase

    % Properties that correspond to app components
    properties (Access = public)
        TMSEMGremotecontrolUIFigure  matlab.ui.Figure
        didt                         matlab.ui.control.NumericEditField
        didtEditFieldLabel           matlab.ui.control.Label
        SaveButton                   matlab.ui.control.Button
        EMGindex                     matlab.ui.control.NumericEditField
        EMGindexEditField_2Label     matlab.ui.control.Label
        TMSindex                     matlab.ui.control.NumericEditField
        TMSindexEditFieldLabel       matlab.ui.control.Label
        AuthorVersionLabel           matlab.ui.control.Label
        NameLabel                    matlab.ui.control.Label
        TabGroup                     matlab.ui.container.TabGroup
        ConnectExGTab                matlab.ui.container.Tab
        ExG_SimulatedEMGCheckBox     matlab.ui.control.CheckBox
        ExG_DeleteButton             matlab.ui.control.Button
        ExG_ConnectButton            matlab.ui.control.StateButton
        ExG_Label                    matlab.ui.control.Label
        ConnectTMSTab                matlab.ui.container.Tab
        TMS_ConnectButton            matlab.ui.control.StateButton
        TMS_LogfileName              matlab.ui.control.EditField
        LogfileEditFieldLabel        matlab.ui.control.Label
        TMS_SerialportName           matlab.ui.control.EditField
        SerialportEditFieldLabel     matlab.ui.control.Label
        TMS_Label                    matlab.ui.control.Label
        AcquireIOcurveTab            matlab.ui.container.Tab
        IO_AmplitudeLimit            matlab.ui.control.Spinner
        AmplitudelimitLabel          matlab.ui.control.Label
        IO_ChannelDropDown           matlab.ui.control.DropDown
        ChannelDropDownLabel         matlab.ui.control.Label
        IO_PauseButton               matlab.ui.control.Button
        IO_StartButton               matlab.ui.control.Button
        IO_StopButton                matlab.ui.control.Button
        IO_maxISISpinner             matlab.ui.control.Spinner
        maxISISpinnerLabel           matlab.ui.control.Label
        IO_minISISpinner             matlab.ui.control.Spinner
        minISISpinnerLabel           matlab.ui.control.Label
        IO_Randomseed                matlab.ui.control.NumericEditField
        RandomseedEditFieldLabel     matlab.ui.control.Label
        IO_MaximumSpinner            matlab.ui.control.Spinner
        MaximumLabel                 matlab.ui.control.Label
        IO_DensemaximumSpinner       matlab.ui.control.Spinner
        DensemaximumSpinnerLabel     matlab.ui.control.Label
        IO_DenseminimumSpinner       matlab.ui.control.Spinner
        DenseminimumSpinnerLabel     matlab.ui.control.Label
        IO_MinimumSpinner            matlab.ui.control.Spinner
        MinimumSpinner_2Label        matlab.ui.control.Label
        IO_Pulses                    matlab.ui.control.NumericEditField
        PulsesEditFieldLabel         matlab.ui.control.Label
        IO_ProgressGauge             matlab.ui.control.Gauge
        ProgressGaugeLabel           matlab.ui.control.Label
    end

    
    properties (Access = private)
        
        % Properties related to built-in data storage
        data=struct('TMS',{[]},'EMG',{[]},'IO',{[]},'triggerIN',{[]}); % A built-in data storage
        data_isSaved=true;                                             % Status variable for save
        
        % Properties related to the EMG visualization (8 figures that are updated programmatically)
        UIAxes matlab.ui.control.UIAxes % An array of UIAxes elements for the EMG
        UIAxesPlot                      % An array of plot elements for faster plotting of the EMG
        UIAxesText                      % An array of text elements for the peak-to-peak values
        
        % Primary timer for the user interface
        UIFigure_timer  timer         % A timer to automatically update the screen
        
        % Class handle for receiving BrainVision ExG amplifier data
        RDA_device BrainVisionRDA % A class handle to the RDA device     
        RDA_index=0;              % RDA event count
        RDA_MEP MEP               % TMS-EMG analysis class, filter() and identify()
        
        % Class handle to control a TMS device
        TMS_device MagProController % A class handle to the TMS device
        TMS_index=0;                % TMS pulse count
        
        % Properties related to IO curve acquisition
        IOC_index=0;
        IOC=struct('seed',0,'limits',[40 55 75 90],'N',0,'pulses',[]);
        IOC_timer timer
        IOC_pulseIndex=1;
        IOC_setAmplitude=true;
        IOC_ISImin=4;
        IOC_ISImax=6;
        IOC_ISI
        IOC_stopwatch
    end
    
    methods (Access = private)
        
        function generate_IOC_sampling(app)
            %GENERATE_IOC_SAMPLING generates a sampling order for IO curve
            
            % Shuffle the pulses, with initial ease in in amplitude:
            %
            %   The first 25% of pulses have an intensity limit:
            %   The first pulse must be from lowest 50% of pulses, and
            %   the N'th pulse must not exceed 50%+2N of pulses in its
            %   intensity.
            %
            %   This is a classical in-place shuffle, except for the
            %   limits; see any standard 'algorithm book'.
            
            % Create an ordered pulse sequence
            pulses=sort([app.IOC.limits(1):app.IOC.limits(4) app.IOC.limits(2):app.IOC.limits(3)]);
            N=length(pulses);

            % Initialize a pseudorandom number generator
            s=RandStream('mt19937ar','Seed',app.IOC.seed);
            
            % Set initial intensity limit to 50% of (sorted) pulses
            n_limit=floor(N/2);
            
            % Select n'th pulse from allowed pulses
            for n=1:N
                % Select random pulse from (remaining) allowed pulses
                %   That is, a pulses between n and N-n_limit
                ind=n-1+randi(s,(N-n_limit)-(n-1),1);
                % Swap that pulse to place 'n' in the list
                tmp=pulses(n);
                pulses(n)=pulses(ind);
                pulses(ind)=tmp;
                % Increate the intensity limit for allowed pulses
                if n_limit>0
                    n_limit=n_limit-2;
                    % n_limit cannot be negative
                    if n_limit<0
                        n_limit=0;
                    end
                end
            end
            app.IOC.pulses=pulses;
            app.IOC.N=N;
            
            % Update GUI elements
            app.IO_ProgressGauge.Limits=[0 app.IOC.N];
            app.IO_Pulses.Value=app.IOC.N;
        end
        
        function sample_IOC(app,src,~)
            %SAMPLE_IOC samples an IO curve (a timer callback function)
            
            % Check that GUI is not closed
            if ~isvalid(app)
                stop(src);
                delete(src);
                return
            end
            
            % Measure time since last TMS pulse
            dt=toc(app.IOC_stopwatch);
            
            % If more than 500 ms has passed, and we have not yet updated
            % the amplitude of the next pulse, we will update the amplitude
            if dt>0.5 && ~app.IOC_setAmplitude
                app.TMS_device.setAmplitude(app.IOC.pulses(app.IOC_pulseIndex));
                app.IOC_setAmplitude=true;
                return
            end
            
            % If more than ISI has passed, we will trigger the next pulse
            if dt>app.IOC_ISI
                
                % Trigger the TMS device
                %
                %   We perform a sanity check and skip any too strong
                %   a pulse also at this point (see below).
                if app.IOC_setAmplitude && app.IOC.pulses(app.IOC_pulseIndex) <= app.IO_AmplitudeLimit.Value
                    app.TMS_device.trigger();
                    app.IOC_setAmplitude=false;
                end
                
                % Increase the pulse counter until next valid pulse; stop if complete
                %
                %   Too strong pulses are primarily skipped here.
                app.IOC_pulseIndex=app.IOC_pulseIndex+1;
                while app.IOC_pulseIndex <= app.IOC.N && app.IOC.pulses(app.IOC_pulseIndex) > app.IO_AmplitudeLimit.Value
                    app.IOC_pulseIndex=app.IOC_pulseIndex+1;
                end
                if app.IOC_pulseIndex>app.IOC.N
                    app.IO_StopButtonPushed([]);
                    return
                end
                
                % Time next TMS pulse
                app.IOC_ISI=app.getISI();
                app.IOC_stopwatch=tic();
                
                % Update GUI elements
                app.IO_ProgressGauge.Value=app.IOC_pulseIndex-1;
            end
        end
        
        function ISI=getISI(app)
            %GETISI yields a random ISI between minimum and maximum value
            ISI=app.IOC_ISImin+(app.IOC_ISImax-app.IOC_ISImin)*rand();
        end
        
        function update_GUI(app,src,~)
            %update_GUI plots EMG data (a timer callback function)
            
            % Check that GUI is not closed
            if ~isvalid(app)
                stop(src);
                delete(src);
                return
            end
            
            % Check for new TMS pulses
            if isvalid(app.TMS_device)
                index=app.TMS_device.pulselist_index;
                if index>app.TMS_index
                    app.TMS_index=index;
                    
                    app.data.TMS{app.TMS_index}=app.TMS_device.pulselist(index);
                    app.data_isSaved=false;
                    
                    app.didt.Value=double(app.TMS_device.pulselist(index).didt);
                    app.TMSindex.Value=index;
                end
            end
             
            % Check for new EMG data
            if isvalid(app.RDA_device)
                if app.RDA_device.hasData()
                    app.RDA_index=app.RDA_index+1;
                    % Read new data
                    x=app.RDA_device.pollData();
                    y=app.RDA_MEP.filter(x);
                    c=app.RDA_MEP.identify(y);
                    
                    app.data.EMG{app.RDA_index}={datetime() x y c};
                    app.data_isSaved=false;
                
                    C=[1 0.75 0.75;1 1 1;0.75 1 0.75];
                    % Plot new data to GUI
                    app.EMGindex.Value=app.RDA_index;
                    for i=1:8
                        set(app.UIAxesText(i),'String',sprintf('%.1f µV',c(i,1)));
                        set(app.UIAxesPlot(i),'YData',y(i,:));
                        set(app.UIAxes(i),'Color',C(2+c(i,2),:));
                    end
                end
            end
            
        end
        
    end
    

    % Callbacks that handle component events
    methods (Access = private)

        % Code that executes after component creation
        function startupFcn(app)
            % Generate UIAxes for the EMG data
            for i=1:8
                app.UIAxes(i)=uiaxes(app.TMSEMGremotecontrolUIFigure);
                title(app.UIAxes(i),sprintf('#%d',i));
                xlabel(app.UIAxes(i),'Time (ms)');
                ylabel(app.UIAxes(i),'EMG (µV)');
                app.UIAxes(i).XLim=[-100 250];
                app.UIAxes(i).YLim=[-100 100];
                app.UIAxes(i).Box='on';
                app.UIAxes(i).LineWidth=2;
                % app.UIAxes(i).XGrid='on';
                % app.UIAxes(i).YGrid='on';
                app.UIAxes(i).Position=[480*mod(i-1,2) 1010-200*floor((i+1)/2) 480 200];
                app.UIAxesPlot(i)=plot(app.UIAxes(i),0.2*(-1000:1750),zeros(1,2751),'k-','LineWidth',2);
                app.UIAxesText(i)=text(app.UIAxes(i),230,50,'0 µV','HorizontalAlignment','right','FontSize',24);
            end
            
            % Set up the filters
            app.RDA_MEP=MEP();
            
            % Generate IO curve for the initial parameters
            app.IO_MinimumSpinner.Value=app.IOC.limits(1);
            app.IO_DenseminimumSpinner.Value=app.IOC.limits(2);
            app.IO_DensemaximumSpinner.Value=app.IOC.limits(3);
            app.IO_MaximumSpinner.Value=app.IOC.limits(4);
            app.generate_IOC_sampling();
            app.IO_ProgressGauge.Limits=[0 app.IOC.N];
            
            app.IO_minISISpinner.Value=app.IOC_ISImin;
            app.IO_maxISISpinner.Value=app.IOC_ISImax;
            
            try
                lines=readlines('EMG_channel_names.txt');
                if lines(end)==""
                    lines=lines(1:end-1);
                end
                items={};
                index=1;
                for linestr=lines'
                    line=char(linestr);
                    if isempty(line) || line(1)=='#'
                        continue
                    end
                    items{end+1}=[num2str(index) ': ' line];
                    index=index+1;
                end
                assert(numel(items)==8,'Incorrect number of items.');
                app.IO_ChannelDropDown.Items=items;
            catch
                disp('Missing or incorrect file ''EMG_channel_names.txt'', using default channel names.');
            end
            
            % Create timer objects
            app.IOC_timer=timer('ExecutionMode','fixedRate','Period',0.050,'BusyMode','drop','TimerFcn',@app.sample_IOC); 
            app.UIFigure_timer=timer('ExecutionMode','fixedRate', 'Period',0.050,'BusyMode','drop','TimerFcn',@app.update_GUI);
            
            start(app.UIFigure_timer);

        end

        % Value changed function: IO_Randomseed
        function IO_RandomseedValueChanged(app, event)
            % IO curve random seed was changed, regenerate sampling
            value=round(app.IO_Randomseed.Value);
            app.IO_Randomseed.Value=value;
            app.IOC.seed=value;
            app.generate_IOC_sampling();
        end

        % Value changed function: IO_MinimumSpinner
        function IO_MinimumSpinnerValueChanged(app, event)
            % IO curve lower bound was changed, regenerate sampling
            value=app.IO_MinimumSpinner.Value;
            if value>app.IO_DenseminimumSpinner.Value
                value=app.IO_DenseminimumSpinner.Value;
                app.IO_MinimumSpinner.Value=value;
            end
            app.IOC.limits(1)=value;
            app.generate_IOC_sampling();
        end

        % Value changed function: IO_DenseminimumSpinner
        function IO_DenseminimumSpinnerValueChanged(app, event)
            % IO curve dense region lower bound was changed, regenerate
            value=app.IO_DenseminimumSpinner.Value;
            if value<app.IO_MinimumSpinner.Value
                value=app.IO_MinimumSpinner.Value;
                app.IO_DenseminimumSpinner.Value=value;
            elseif value>app.IO_DensemaximumSpinner.Value
                value=app.IO_DensemaximumSpinner.Value;
                app.IO_DenseminimumSpinner.Value=value;
            end            
            app.IOC.limits(2)=value;
            app.generate_IOC_sampling();    
        end

        % Value changed function: IO_DensemaximumSpinner
        function IO_DensemaximumSpinnerValueChanged(app, event)
            % IO curve dense region upper bound was changed, regenrate
            value=app.IO_DensemaximumSpinner.Value;
            if value<app.IO_DenseminimumSpinner.Value
                value=app.IO_DenseminimumSpinner.Value;
                app.IO_DensemaximumSpinner.Value=value;
            elseif value>app.IO_MaximumSpinner.Value
                value=app.IO_MaximumSpinner.Value;
                app.IO_DensemaximumSpinner.Value=value;
            end 
            app.IOC.limits(3)=value;           
            app.generate_IOC_sampling();            
        end

        % Value changed function: IO_MaximumSpinner
        function IO_MaximumSpinnerValueChanged(app, event)
            % IO curve upper bound was changed, regenerate sampling
            value=app.IO_MaximumSpinner.Value;
            if value<app.IO_DensemaximumSpinner.Value
                value=app.IO_DensemaximumSpinner.Value;
                app.IO_MaximumSpinner.Value=value;
            end
            app.IO_AmplitudeLimit.Value=value;
            app.IOC.limits(4)=value;
            app.generate_IOC_sampling();
        end

        % Button pushed function: IO_StartButton
        function IO_StartButtonPushed(app, event)
            % Start IO curve acquisition
            
            % Check for TMS device
            if isempty(app.TMS_device)
                uialert(app.TMSEMGremotecontrolUIFigure,'Connect TMS device first','No TMS device found','CloseFcn',@(~,~) figure(app.TMSEMGremotecontrolUIFigure));
                return
            else 
                % Disabled TMS device disconnection
                app.TMS_ConnectButton.Enable=false;
            end
            
            % Disable controls, enable cancel button
            app.IO_ProgressGauge.Enable=true;
            app.IO_Randomseed.Editable=false;
            app.IO_MinimumSpinner.Enable=false;
            app.IO_DenseminimumSpinner.Enable=false;
            app.IO_DensemaximumSpinner.Enable=false;
            app.IO_MaximumSpinner.Enable=false;
            app.IO_AmplitudeLimit.Enable=false;
            app.IO_minISISpinner.Enable=false;
            app.IO_maxISISpinner.Enable=false;
            app.IO_StopButton.Enable=true;
            app.IO_PauseButton.Enable=true;
            app.IO_StartButton.Enable=false;
              
            % Start IO curve acquisition timer
            if strcmp(app.IOC_timer.Running,'off')
                if app.IOC_pulseIndex==1
                    % Add IO curve pulse sequence to data storage
                    app.IOC_index=app.IOC_index+1;
                    app.data.IO{app.IOC_index}={};
                    app.data.IO{app.IOC_index}{end+1}={datetime() app.IO_ChannelDropDown.Value app.IOC.pulses app.TMS_index app.RDA_index [app.IOC_ISImin app.IOC_ISImax] app.IO_AmplitudeLimit.Value 'START'};
                    app.data_isSaved=false;
                else
                    app.data.IO{app.IOC_index}{end+1}={datetime() app.IO_ChannelDropDown.Value app.IOC.pulses app.TMS_index app.RDA_index [app.IOC_ISImin app.IOC_ISImax] app.IO_AmplitudeLimit.Value 'MODIFY'};
                    app.data_isSaved=false;
                end
                
                % Enable TMS device
                app.TMS_device.setStatus(1);
                pause(0.1);
                % Charge the TMS device for the next pulse
                app.TMS_device.setAmplitude(app.IOC.pulses(app.IOC_pulseIndex));
                
                % Generate random delay for the next pulse
                app.IOC_ISI=app.getISI();
                app.IOC_stopwatch=tic();
                
                % Set timer to run
                start(app.IOC_timer);
            end
            
            drawnow();
            figure(app.TMSEMGremotecontrolUIFigure);
        end

        % Button pushed function: IO_PauseButton
        function IO_PauseButtonPushed(app, event)
            % Temporatily halt IO curve acquisition
            
            % Stop IO curve acquisition timer
            stop(app.IOC_timer);
            
            % Disable TMS device            
            app.TMS_device.setStatus(0);
            
            % Partially enable the controls
            app.IO_AmplitudeLimit.Enable=true;
            app.IO_minISISpinner.Enable=true;
            app.IO_maxISISpinner.Enable=true;
            app.IO_StartButton.Enable=true;
            app.IO_PauseButton.Enable=false;
            
            drawnow();
            figure(app.TMSEMGremotecontrolUIFigure);
        end

        % Button pushed function: IO_StopButton
        function IO_StopButtonPushed(app, event)
            % Stop and cancel IO curve acquisition
            
            % Stop the timer
            stop(app.IOC_timer);
            
            % Add IO curve pulse sequence to data storage
            app.data.IO{app.IOC_index}{end+1}={datetime() app.IO_ChannelDropDown.Value app.IOC.pulses app.TMS_index app.RDA_index [app.IOC_ISImin app.IOC_ISImax] app.IO_AmplitudeLimit.Value 'END'};
            app.data_isSaved=false;
            
            % Disable TMS device 
            app.TMS_device.setStatus(0);
            
            % Enable TMS device disconnect button
            app.TMS_ConnectButton.Enable=true;
            
            % Rese the IO curve acquision counter
            app.IOC_pulseIndex=1;
            
            % Enable controls, disable cancel button
            app.IO_ProgressGauge.Value=0;
            app.IO_ProgressGauge.Enable=false;
            app.IO_Randomseed.Editable=true;
            app.IO_MinimumSpinner.Enable=true;
            app.IO_DenseminimumSpinner.Enable=true;
            app.IO_DensemaximumSpinner.Enable=true;
            app.IO_MaximumSpinner.Enable=true;
            app.IO_AmplitudeLimit.Enable=true;
            app.IO_minISISpinner.Enable=true;
            app.IO_maxISISpinner.Enable=true;
            app.IO_StartButton.Enable=true;
            app.IO_PauseButton.Enable=false;
            app.IO_StopButton.Enable=false;
            
            drawnow();
            figure(app.TMSEMGremotecontrolUIFigure);
        end

        % Value changed function: TMS_ConnectButton
        function TMS_ConnectButtonValueChanged(app, event)
            value = app.TMS_ConnectButton.Value;
            if value==1
                app.TMS_SerialportName.Editable=false;
                app.TMS_LogfileName.Editable=false;
                serialport=app.TMS_SerialportName.Value;
                logfile=app.TMS_LogfileName.Value;
                try
                    if ~isempty(logfile)
                        app.TMS_device=MagProController(serialport,[logfile '.txt']);
                    else
                        app.TMS_device=MagProController(serialport);
                        app.TMS_SerialportName.Editable=true;
                        app.TMS_LogfileName.Editable=true;
                    end
                catch
                    uialert(app.TMSEMGremotecontrolUIFigure,{'Could not connect to TMS device.';'Most likely cause, the serial port is already in use.'},'Could not connect to the TMS device!');
                    app.TMS_ConnectButton.Value=0;
                    app.TMS_SerialportName.Editable=true;
                    app.TMS_LogfileName.Editable=true;
                end
            else
                app.TMS_device.setStatus(0);
                delete(app.TMS_device);
            end
            
            drawnow();
            figure(app.TMSEMGremotecontrolUIFigure);
        end

        % Value changed function: ExG_ConnectButton
        function ExG_ConnectButtonValueChanged(app, event)
            if app.ExG_ConnectButton.Value
                if ~isempty(gcp('nocreate'))
                    uialert(app.TMSEMGremotecontrolUIFigure,{'The MATLAB parallel pool is already in use.';'If this is not intentional, kill it with ''delete(gcp(''nocreate''))'''},'Parallel pool is already in use!');
                    app.ExG_ConnectButton.Value=false;
                    return
                end
                app.ExG_DeleteButton.Enable=false;
                app.ExG_SimulatedEMGCheckBox.Enable=false;
                dialog=uiprogressdlg(app.TMSEMGremotecontrolUIFigure,'Title','Opening RDA connection','Indeterminate','on');
                if app.ExG_SimulatedEMGCheckBox.Value
                    % Open a simulated RDA session, with data every second
                    app.RDA_device=BrainVisionRDA(1);
                else
                    % Open a real RDA session
                    app.RDA_device=BrainVisionRDA();
                end
                close(dialog);
            else
                dialog=uiprogressdlg(app.TMSEMGremotecontrolUIFigure,'Title','Closing RDA connection','Indeterminate','on');
                delete(app.RDA_device);
                app.ExG_DeleteButton.Enable=true;
                app.ExG_SimulatedEMGCheckBox.Enable=true;
                close(dialog);
            end
            
            drawnow();
            figure(app.TMSEMGremotecontrolUIFigure);
        end

        % Button pushed function: ExG_DeleteButton
        function ExG_DeleteButtonPushed(app, event)
            % Delete parallel pool if such exists
            if ~isempty(gcp('nocreate'))
                delete(gcp('nocreate'));
            end
            
            drawnow();
            figure(app.TMSEMGremotecontrolUIFigure);
        end

        % Value changed function: IO_minISISpinner
        function IO_minISISpinnerValueChanged(app, event)
            % Update minimum ISI, it cannot exceed maximum ISI
            value=app.IO_minISISpinner.Value;
            if value>app.IO_maxISISpinner.Value
                value=app.IO_maxISISpinner.Value;
                app.IO_minISISpinner.Value=value;
            end
            app.IOC_ISImin=value; 
        end

        % Value changed function: IO_maxISISpinner
        function IO_maxISISpinnerValueChanged(app, event)
            % Update maximum ISI, it cannot be below minimum ISI
            value=app.IO_maxISISpinner.Value;
            if value<app.IO_minISISpinner.Value
                value=app.IO_minISISpinner.Value;
                app.IO_maxISISpinner.Value=value;
            end
            app.IOC_ISImax=value;
        end

        % Close request function: TMSEMGremotecontrolUIFigure
        function TMSEMGremotecontrolUIFigureCloseRequest(app, event)
            % If there is unsaved data, confirm before closing
            if ~app.data_isSaved
                selection=uiconfirm(app.TMSEMGremotecontrolUIFigure,...
                        'Save EMG data before closing?','Save data?', ...
                        'Options',{'Save','Don''t save','Cancel'},...
                        'DefaultOption',1,'CancelOption',3);
                switch selection
                    case 'Save'
                        [filename,path]=uiputfile('*.mat','Save EMG data:');
                        if isequal(filename,0)
                            return % User did not select a file to save
                        end
                        data=app.data;
                        description=sprintf('TMS-EMG data saved at %s',datestr(clock(),'yyyy-mm-dd HH:MM:SS.FFF'));
                        save(fullfile(path,filename),'data','description');
                    case 'Don''t save'
                    case 'Cancel'
                        drawnow();
                        figure(app.TMSEMGremotecontrolUIFigure);
                        return
                end
            end
            % Stop IO curve acquisition, if any
            stop(app.IOC_timer);
            % Stop UI update
            stop(app.UIFigure_timer);
            % Disconnect TMS device, if any
            if app.TMS_ConnectButton.Value==true
                app.TMS_ConnectButton.Value=false;
                app.TMS_ConnectButtonValueChanged([]);
            end
            % Disconnect ExG, if any
            if app.ExG_ConnectButton.Value==true
                app.ExG_ConnectButton.Value=false;
                app.ExG_ConnectButtonValueChanged([]);
            end
            delete(app);
        end

        % Button pushed function: SaveButton
        function SaveButtonPushed(app, event)
            % Save the EMG data, and mark it as saved
            %   The mark of being saved is removed when new data arrives
            [filename,path]=uiputfile('*.mat','Save EMG data:');
            
            drawnow();
            figure(app.TMSEMGremotecontrolUIFigure);
            
            if isequal(filename,0)
                return % User did not select a file into which to save.
            end
            data=app.data;
            description=sprintf('TMS-EMG data saved at %s',datestr(clock(),'yyyy-mm-dd HH:MM:SS.FFF'));
            save(fullfile(path,filename),'data','description');
            app.data_isSaved=true;
            
        end

        % Window key press function: TMSEMGremotecontrolUIFigure
        function TMSEMGremotecontrolUIFigureWindowKeyPress(app, event)
            key=event.Key;
            if strcmp(key,'f13') % User pressed the foot pedal
                % If possible, pause IO curve acquisition
                % Otherwise, if possible, start such acquisition
                if app.IO_PauseButton.Enable
                    app.IO_PauseButtonPushed([]);
                elseif app.IO_StartButton.Enable
                    app.IO_StartButtonPushed([]);
                end
            elseif strcmp(key,'f14') % A TMS pulse trigger
                % Add a trigger input signal to output file
                app.data.triggerIN{end+1}=datetime();
                app.data_isSaved=false;
            end
        end
    end

    % Component initialization
    methods (Access = private)

        % Create UIFigure and components
        function createComponents(app)

            % Create TMSEMGremotecontrolUIFigure and hide until all components are created
            app.TMSEMGremotecontrolUIFigure = uifigure('Visible', 'off');
            app.TMSEMGremotecontrolUIFigure.Position = [960 40 960 1010];
            app.TMSEMGremotecontrolUIFigure.Name = 'TMS-EMG remote control';
            app.TMSEMGremotecontrolUIFigure.Resize = 'off';
            app.TMSEMGremotecontrolUIFigure.CloseRequestFcn = createCallbackFcn(app, @TMSEMGremotecontrolUIFigureCloseRequest, true);
            app.TMSEMGremotecontrolUIFigure.WindowKeyPressFcn = createCallbackFcn(app, @TMSEMGremotecontrolUIFigureWindowKeyPress, true);

            % Create TabGroup
            app.TabGroup = uitabgroup(app.TMSEMGremotecontrolUIFigure);
            app.TabGroup.Position = [0 0 640 210];

            % Create ConnectExGTab
            app.ConnectExGTab = uitab(app.TabGroup);
            app.ConnectExGTab.Title = 'Connect ExG';

            % Create ExG_Label
            app.ExG_Label = uilabel(app.ConnectExGTab);
            app.ExG_Label.Position = [16 101 467 70];
            app.ExG_Label.Text = {'The connection to ExG amplifier is made via the BrainVision Recorder RDA interface.'; 'You must first start BrainVision Recorder, and set it to record and *save* data.'; ''; 'The connection creates a background process in a ''parallel pool.'''; 'Starting the pool takes about 15 s, and shutting it down takes about 5 s.'; ''};

            % Create ExG_ConnectButton
            app.ExG_ConnectButton = uibutton(app.ConnectExGTab, 'state');
            app.ExG_ConnectButton.ValueChangedFcn = createCallbackFcn(app, @ExG_ConnectButtonValueChanged, true);
            app.ExG_ConnectButton.Text = 'Connect';
            app.ExG_ConnectButton.Position = [208 14 260 63];

            % Create ExG_DeleteButton
            app.ExG_DeleteButton = uibutton(app.ConnectExGTab, 'push');
            app.ExG_DeleteButton.ButtonPushedFcn = createCallbackFcn(app, @ExG_DeleteButtonPushed, true);
            app.ExG_DeleteButton.BackgroundColor = [1 0 0];
            app.ExG_DeleteButton.Position = [16 16 178 22];
            app.ExG_DeleteButton.Text = 'delete(gpc(''nocreate''))';

            % Create ExG_SimulatedEMGCheckBox
            app.ExG_SimulatedEMGCheckBox = uicheckbox(app.ConnectExGTab);
            app.ExG_SimulatedEMGCheckBox.Text = 'Simulated EMG';
            app.ExG_SimulatedEMGCheckBox.Position = [519 149 106 22];

            % Create ConnectTMSTab
            app.ConnectTMSTab = uitab(app.TabGroup);
            app.ConnectTMSTab.Title = 'Connect TMS';

            % Create TMS_Label
            app.TMS_Label = uilabel(app.ConnectTMSTab);
            app.TMS_Label.Position = [16 115 467 56];
            app.TMS_Label.Text = {'The connection to MagVenture MagPro device is via a serial port.'; 'You must name the serial port device to which the MagPro device is connected.'; ''; 'On MagPro device, the serial cable goes to connector ''COM2'' (the lowest connector).'};

            % Create SerialportEditFieldLabel
            app.SerialportEditFieldLabel = uilabel(app.ConnectTMSTab);
            app.SerialportEditFieldLabel.HorizontalAlignment = 'right';
            app.SerialportEditFieldLabel.Position = [17 55 63 22];
            app.SerialportEditFieldLabel.Text = 'Serial port:';

            % Create TMS_SerialportName
            app.TMS_SerialportName = uieditfield(app.ConnectTMSTab, 'text');
            app.TMS_SerialportName.Position = [95 55 100 22];
            app.TMS_SerialportName.Value = 'COM3';

            % Create LogfileEditFieldLabel
            app.LogfileEditFieldLabel = uilabel(app.ConnectTMSTab);
            app.LogfileEditFieldLabel.HorizontalAlignment = 'right';
            app.LogfileEditFieldLabel.Position = [17 16 48 22];
            app.LogfileEditFieldLabel.Text = 'Log file:';

            % Create TMS_LogfileName
            app.TMS_LogfileName = uieditfield(app.ConnectTMSTab, 'text');
            app.TMS_LogfileName.Position = [95 16 100 22];

            % Create TMS_ConnectButton
            app.TMS_ConnectButton = uibutton(app.ConnectTMSTab, 'state');
            app.TMS_ConnectButton.ValueChangedFcn = createCallbackFcn(app, @TMS_ConnectButtonValueChanged, true);
            app.TMS_ConnectButton.Text = 'Connect';
            app.TMS_ConnectButton.Position = [208 14 260 63];

            % Create AcquireIOcurveTab
            app.AcquireIOcurveTab = uitab(app.TabGroup);
            app.AcquireIOcurveTab.AutoResizeChildren = 'off';
            app.AcquireIOcurveTab.Title = 'Acquire IO curve';

            % Create ProgressGaugeLabel
            app.ProgressGaugeLabel = uilabel(app.AcquireIOcurveTab);
            app.ProgressGaugeLabel.HorizontalAlignment = 'center';
            app.ProgressGaugeLabel.Enable = 'off';
            app.ProgressGaugeLabel.Position = [403 13 57 22];
            app.ProgressGaugeLabel.Text = 'Progress:';

            % Create IO_ProgressGauge
            app.IO_ProgressGauge = uigauge(app.AcquireIOcurveTab, 'circular');
            app.IO_ProgressGauge.Enable = 'off';
            app.IO_ProgressGauge.Position = [340 50 120 120];

            % Create PulsesEditFieldLabel
            app.PulsesEditFieldLabel = uilabel(app.AcquireIOcurveTab);
            app.PulsesEditFieldLabel.Position = [16 17 50 22];
            app.PulsesEditFieldLabel.Text = 'Pulses:';

            % Create IO_Pulses
            app.IO_Pulses = uieditfield(app.AcquireIOcurveTab, 'numeric');
            app.IO_Pulses.Editable = 'off';
            app.IO_Pulses.Position = [115 16 50 22];

            % Create MinimumSpinner_2Label
            app.MinimumSpinner_2Label = uilabel(app.AcquireIOcurveTab);
            app.MinimumSpinner_2Label.Position = [16 136 58 22];
            app.MinimumSpinner_2Label.Text = 'Minimum:';

            % Create IO_MinimumSpinner
            app.IO_MinimumSpinner = uispinner(app.AcquireIOcurveTab);
            app.IO_MinimumSpinner.Limits = [0 100];
            app.IO_MinimumSpinner.ValueDisplayFormat = '%6.4g';
            app.IO_MinimumSpinner.ValueChangedFcn = createCallbackFcn(app, @IO_MinimumSpinnerValueChanged, true);
            app.IO_MinimumSpinner.Position = [115 136 50 22];
            app.IO_MinimumSpinner.Value = 40;

            % Create DenseminimumSpinnerLabel
            app.DenseminimumSpinnerLabel = uilabel(app.AcquireIOcurveTab);
            app.DenseminimumSpinnerLabel.Position = [16 106 96 22];
            app.DenseminimumSpinnerLabel.Text = 'Dense minimum:';

            % Create IO_DenseminimumSpinner
            app.IO_DenseminimumSpinner = uispinner(app.AcquireIOcurveTab);
            app.IO_DenseminimumSpinner.Limits = [0 100];
            app.IO_DenseminimumSpinner.ValueDisplayFormat = '%6.4g';
            app.IO_DenseminimumSpinner.ValueChangedFcn = createCallbackFcn(app, @IO_DenseminimumSpinnerValueChanged, true);
            app.IO_DenseminimumSpinner.Position = [115 106 50 22];
            app.IO_DenseminimumSpinner.Value = 55;

            % Create DensemaximumSpinnerLabel
            app.DensemaximumSpinnerLabel = uilabel(app.AcquireIOcurveTab);
            app.DensemaximumSpinnerLabel.Position = [16 76 99 22];
            app.DensemaximumSpinnerLabel.Text = 'Dense maximum:';

            % Create IO_DensemaximumSpinner
            app.IO_DensemaximumSpinner = uispinner(app.AcquireIOcurveTab);
            app.IO_DensemaximumSpinner.Limits = [0 100];
            app.IO_DensemaximumSpinner.ValueDisplayFormat = '%6.4g';
            app.IO_DensemaximumSpinner.ValueChangedFcn = createCallbackFcn(app, @IO_DensemaximumSpinnerValueChanged, true);
            app.IO_DensemaximumSpinner.Position = [115 76 50 22];
            app.IO_DensemaximumSpinner.Value = 75;

            % Create MaximumLabel
            app.MaximumLabel = uilabel(app.AcquireIOcurveTab);
            app.MaximumLabel.Position = [16 46 61 22];
            app.MaximumLabel.Text = 'Maximum:';

            % Create IO_MaximumSpinner
            app.IO_MaximumSpinner = uispinner(app.AcquireIOcurveTab);
            app.IO_MaximumSpinner.Limits = [0 100];
            app.IO_MaximumSpinner.ValueDisplayFormat = '%6.4g';
            app.IO_MaximumSpinner.ValueChangedFcn = createCallbackFcn(app, @IO_MaximumSpinnerValueChanged, true);
            app.IO_MaximumSpinner.Position = [115 46 50 22];
            app.IO_MaximumSpinner.Value = 90;

            % Create RandomseedEditFieldLabel
            app.RandomseedEditFieldLabel = uilabel(app.AcquireIOcurveTab);
            app.RandomseedEditFieldLabel.Position = [180 136 84 22];
            app.RandomseedEditFieldLabel.Text = 'Random seed:';

            % Create IO_Randomseed
            app.IO_Randomseed = uieditfield(app.AcquireIOcurveTab, 'numeric');
            app.IO_Randomseed.Limits = [0 4294967295];
            app.IO_Randomseed.ValueChangedFcn = createCallbackFcn(app, @IO_RandomseedValueChanged, true);
            app.IO_Randomseed.Position = [269 136 50 22];

            % Create minISISpinnerLabel
            app.minISISpinnerLabel = uilabel(app.AcquireIOcurveTab);
            app.minISISpinnerLabel.Position = [481 136 47 22];
            app.minISISpinnerLabel.Text = 'min(ISI)';

            % Create IO_minISISpinner
            app.IO_minISISpinner = uispinner(app.AcquireIOcurveTab);
            app.IO_minISISpinner.Step = 0.1;
            app.IO_minISISpinner.Limits = [1 60];
            app.IO_minISISpinner.ValueDisplayFormat = '%6.1f';
            app.IO_minISISpinner.ValueChangedFcn = createCallbackFcn(app, @IO_minISISpinnerValueChanged, true);
            app.IO_minISISpinner.Position = [540 136 60 22];
            app.IO_minISISpinner.Value = 4;

            % Create maxISISpinnerLabel
            app.maxISISpinnerLabel = uilabel(app.AcquireIOcurveTab);
            app.maxISISpinnerLabel.Position = [481 106 51 22];
            app.maxISISpinnerLabel.Text = 'max(ISI)';

            % Create IO_maxISISpinner
            app.IO_maxISISpinner = uispinner(app.AcquireIOcurveTab);
            app.IO_maxISISpinner.Step = 0.1;
            app.IO_maxISISpinner.Limits = [1 60];
            app.IO_maxISISpinner.ValueDisplayFormat = '%6.1f';
            app.IO_maxISISpinner.ValueChangedFcn = createCallbackFcn(app, @IO_maxISISpinnerValueChanged, true);
            app.IO_maxISISpinner.Position = [540 106 60 22];
            app.IO_maxISISpinner.Value = 6;

            % Create IO_StopButton
            app.IO_StopButton = uibutton(app.AcquireIOcurveTab, 'push');
            app.IO_StopButton.ButtonPushedFcn = createCallbackFcn(app, @IO_StopButtonPushed, true);
            app.IO_StopButton.BackgroundColor = [1 0 0];
            app.IO_StopButton.Enable = 'off';
            app.IO_StopButton.Position = [481 76 149 22];
            app.IO_StopButton.Text = 'Stop';

            % Create IO_StartButton
            app.IO_StartButton = uibutton(app.AcquireIOcurveTab, 'push');
            app.IO_StartButton.ButtonPushedFcn = createCallbackFcn(app, @IO_StartButtonPushed, true);
            app.IO_StartButton.BackgroundColor = [0 1 0];
            app.IO_StartButton.Position = [481 16 148 22];
            app.IO_StartButton.Text = 'Start';

            % Create IO_PauseButton
            app.IO_PauseButton = uibutton(app.AcquireIOcurveTab, 'push');
            app.IO_PauseButton.ButtonPushedFcn = createCallbackFcn(app, @IO_PauseButtonPushed, true);
            app.IO_PauseButton.BackgroundColor = [1 1 0.0667];
            app.IO_PauseButton.Enable = 'off';
            app.IO_PauseButton.Position = [481 46 149 22];
            app.IO_PauseButton.Text = 'Pause';

            % Create ChannelDropDownLabel
            app.ChannelDropDownLabel = uilabel(app.AcquireIOcurveTab);
            app.ChannelDropDownLabel.HorizontalAlignment = 'right';
            app.ChannelDropDownLabel.Position = [180 16 60 22];
            app.ChannelDropDownLabel.Text = 'Channel #';

            % Create IO_ChannelDropDown
            app.IO_ChannelDropDown = uidropdown(app.AcquireIOcurveTab);
            app.IO_ChannelDropDown.Items = {'1', '2', '3', '4', '5', '6', '7', '8'};
            app.IO_ChannelDropDown.Position = [255 16 119 22];
            app.IO_ChannelDropDown.Value = '1';

            % Create AmplitudelimitLabel
            app.AmplitudelimitLabel = uilabel(app.AcquireIOcurveTab);
            app.AmplitudelimitLabel.Position = [184 106 87 22];
            app.AmplitudelimitLabel.Text = 'Amplitude limit:';

            % Create IO_AmplitudeLimit
            app.IO_AmplitudeLimit = uispinner(app.AcquireIOcurveTab);
            app.IO_AmplitudeLimit.Limits = [0 100];
            app.IO_AmplitudeLimit.ValueDisplayFormat = '%6.4g';
            app.IO_AmplitudeLimit.Position = [270 106 50 22];
            app.IO_AmplitudeLimit.Value = 90;

            % Create NameLabel
            app.NameLabel = uilabel(app.TMSEMGremotecontrolUIFigure);
            app.NameLabel.FontWeight = 'bold';
            app.NameLabel.Position = [665 46 152 22];
            app.NameLabel.Text = 'TMS–EMG remote control';

            % Create AuthorVersionLabel
            app.AuthorVersionLabel = uilabel(app.TMSEMGremotecontrolUIFigure);
            app.AuthorVersionLabel.Position = [665 19 119 28];
            app.AuthorVersionLabel.Text = {'Author: Lari Koponen'; 'Version: 0.1'; ''};

            % Create TMSindexEditFieldLabel
            app.TMSindexEditFieldLabel = uilabel(app.TMSEMGremotecontrolUIFigure);
            app.TMSindexEditFieldLabel.HorizontalAlignment = 'right';
            app.TMSindexEditFieldLabel.Position = [667 149 66 22];
            app.TMSindexEditFieldLabel.Text = 'TMS index:';

            % Create TMSindex
            app.TMSindex = uieditfield(app.TMSEMGremotecontrolUIFigure, 'numeric');
            app.TMSindex.Editable = 'off';
            app.TMSindex.Position = [748 149 100 22];

            % Create EMGindexEditField_2Label
            app.EMGindexEditField_2Label = uilabel(app.TMSEMGremotecontrolUIFigure);
            app.EMGindexEditField_2Label.HorizontalAlignment = 'right';
            app.EMGindexEditField_2Label.Position = [665 115 68 22];
            app.EMGindexEditField_2Label.Text = 'EMG index:';

            % Create EMGindex
            app.EMGindex = uieditfield(app.TMSEMGremotecontrolUIFigure, 'numeric');
            app.EMGindex.Editable = 'off';
            app.EMGindex.Position = [748 115 100 22];

            % Create SaveButton
            app.SaveButton = uibutton(app.TMSEMGremotecontrolUIFigure, 'push');
            app.SaveButton.ButtonPushedFcn = createCallbackFcn(app, @SaveButtonPushed, true);
            app.SaveButton.Position = [748 81 100 22];
            app.SaveButton.Text = 'Save EMG data';

            % Create didtEditFieldLabel
            app.didtEditFieldLabel = uilabel(app.TMSEMGremotecontrolUIFigure);
            app.didtEditFieldLabel.HorizontalAlignment = 'right';
            app.didtEditFieldLabel.Position = [705 185 28 22];
            app.didtEditFieldLabel.Text = 'di/dt';

            % Create didt
            app.didt = uieditfield(app.TMSEMGremotecontrolUIFigure, 'numeric');
            app.didt.Editable = 'off';
            app.didt.Position = [748 185 100 22];

            % Show the figure after all components are created
            app.TMSEMGremotecontrolUIFigure.Visible = 'on';
        end
    end

    % App creation and deletion
    methods (Access = public)

        % Construct app
        function app = TMSEMG_exported

            % Create UIFigure and components
            createComponents(app)

            % Register the app with App Designer
            registerApp(app, app.TMSEMGremotecontrolUIFigure)

            % Execute the startup function
            runStartupFcn(app, @startupFcn)

            if nargout == 0
                clear app
            end
        end

        % Code that executes before app deletion
        function delete(app)

            % Delete UIFigure when app is deleted
            delete(app.TMSEMGremotecontrolUIFigure)
        end
    end
end