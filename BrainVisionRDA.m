classdef BrainVisionRDA<handle
    %BRAINVISIONRDA opens a background process to acquire EMG data
    %
    %   As MATLAB does not allow general purpose threads,
    %   this class needs 'Parallel Processing Toolbox' for its thread.
    %
    %   In addition, the class uses 'pnet' toolbox by Peter Rydesäter.
    %   This toolbox is outdated and should ideally be replaced with
    %   'tcpclient' (introduced in 'MATLAB R2014b' which further requires
    %   the 'Instrument Control Toolbox'.
    %
    % BRAINVISIONRDA properties:
    %   No public properties.
    %
    % BRAINVISIONRDA methods:
    %   hasData() - The worker unprocessed pieces of data.
    %   pollData() - Get first unprocessed piece of data from the worker.
    %
    % BRAINVISIONRDA static methods (internal, public due to a limitation
    % in 'Parallel Processing Toolbox', do not call these directly):
    %   RDA()
    %   ReadData()
    %   RDAsimulation()
    %
    % Author Lari Koponen
    % Version 2021-04-21
    
    properties(Access=private)
        pool
        queue
        thread
    end
    
    methods
        function obj=BrainVisionRDA(varargin)
            %BRAINVISIONRDA opens the RDA connection
            %
            %   Note that only one BRAINVISIONRDA can be ran at once.
            %   And, that it needs the only 'parallel pool' of current
            %   MATLAB instance. Otherwise, an error is produced.
            %
            %   Note that starting the worker can take up to 20 s
            %  
            %   BRAINVISIONRDA() - Real connection to BrainVision Recorder.
            %
            %   BRAINVISIONDRA(dt>0) - Infinite stream of prerecorded data,
            %                          one piece every 'dt' seconds.
            %
            % Author Lari Koponen
            % Version 2021-04-17
            
            % Check that no 'parallel pool' is in use
            assert(isempty(gcp('nocreate')), ...
                'The ''parallel pool'' is already in use.');
            
            % Open a parallel pool
            obj.pool=parpool(1);  
            
            % Create a data queue for the background worker
            obj.queue=parallel.pool.PollableDataQueue;
            
            if nargin>0 && isnumeric(varargin{1}) && varargin{1}>0
                % Launch worker with 'fake' recording
                obj.thread=parfeval(@BrainVisionRDA.RDAsimulation,0,obj.queue,varargin{1});
            else
                % Launch the real background worker
                obj.thread=parfeval(@BrainVisionRDA.RDA,0,obj.queue);
            end
        end
        
        function delete(obj)
            %DELETE closes the RDA connection, frees 'parallel pool'
            %
            %   Note that closing the worker can take up to 5 se
            %   
            % Author Lari Koponen
            % Version 2021-04-17
            
            % Delete the parallel pool, which kills the worker within.
            delete(obj.pool);
        end
        
        function status=hasData(obj)
            %HASDATA checks if there is unprocessed data from the worker.
            %   
            % Author Lari Koponen
            % Version 2021-04-17
            
            status=(obj.queue.QueueLength>0);
        end
        
        function data=pollData(obj)
            %POLLDATA returns oldest unprocessed data from the worker
            %
            %   This marks the piece of data as processed.
            %   
            %   If there is no data, an error is thrown
            %
            % Author Lari Koponen
            % Version 2021-04-17
            
            assert(obj.hasData(),'No data to poll.');
            
            data=poll(obj.queue);
        end
    end
    
    methods(Static)
        function RDAsimulation(queue,dt)
            %RDASIMULATION creates a stream of 'fake' (prerecorder) data
            %
            % Author Lari Koponen
            % Version 2021-04-17

            load('ExG_demo_20210421.mat','ExG_demo');
            
            index=1;
            while true
                pause(dt);
                data=ExG_demo.data{index};
                send(queue,data);
                index=mod(index,ExG_demo.N_trigger)+1;
            end
        end
        
        function RDA(queue)
            %RDA opens a real RDA connection
            %
            %   Loosely based on the example code by BrainVision, mostly to
            %   get the internal data structure of the UDP data packets.
            %
            %   Assumes that MATLAB is running on the same computer as the
            %   BrainVision Recorder. This is a fixed assumption as this is
            %   the most reasonable configuration to run these two. Adjust
            %   if needed. And, as mentioned in the overall help for the
            %   class, this routine should be rewritten to use 'tcpclient',
            %   a MATLAB internal TCP/IP protocol introduced in 2014,
            %   rather than the 15 years old 'pnet' MEX file. But, it ain't
            %   broken, yet, so I did not fix it.
            %
            % Author Lari Koponen
            % Version 2021-04-21

            % Channel order from the amplifier
            channel_order={'1','2','3','4','5','6','7','8'};

            % A list of unprocessed triggers
            unprocessed_triggers=[];
            
            % A one-second buffer for the data
            data_last_second=zeros(8,5000,'single');

            % IP address for the Recorder, here 'localhost'
            recorder_IP = '127.0.0.1';

            % Port for the connection
            %   Default is for 32-bit data, alternative for 16-bit data
            if true
                recorder_port=51244;
            else
                recorder_port=51234;
            end

            % Open a TCP/IP connection to the BrainVision Recorder
            recorder=pnet('tcpconnect',recorder_IP,recorder_port);
            if pnet(recorder,'status')==0
                error('Failed to connect to the BrainVision Recorder.');
            end

            % BrainVision data package parameters, do not edit.
            header_size=24;

            finish=false;
            while ~finish
                try
                    % Check for data in the socket buffer
                    data1=pnet(recorder,'read',header_size,'byte','network','view','noblock');

                    % Process the data in the socket buffer
                    while ~isempty(data1)

                        % Read an RDA message header
                        header=struct('uid',[],'size',[],'type',[]);
                        header.uid=pnet(recorder,'read',16);
                        header.size=swapbytes(pnet(recorder,'read',1,'uint32','network'));
                        header.type=swapbytes(pnet(recorder,'read',1,'uint32','network'));

                        % Perform some action depending of the type of the data package
                        switch header.type
                            case 1       % Start, read ExG properties & initialize

                                % Read the ExG properties
                                properties=struct('channelCount',[],'samplingInterval',[],'resolutions',[],'channelNames',[]);
                                properties.channelCount=swapbytes(pnet(recorder,'read',1,'uint32','network'));
                                properties.samplingInterval=swapbytes(pnet(recorder,'read',1,'double','network'));
                                properties.resolutions=swapbytes(pnet(recorder,'read',properties.channelCount,'double','network'));
                                tmp=strsplit(pnet(recorder,'read',header.size-36-properties.channelCount*8),'\0');
                                properties.channelNames=tmp(1:end-1);
                                assert(all(strcmp(channel_order,properties.channelNames)),'The channel order in data is unexpected!');

                                % Reset block counter to check overflows
                                index_block=-1;

                            case 4       % Read a 32-bit data block, each block has 100 time points (20 ms at 5000 Hz)

                                % Read a block of data
                                [header_data,data,markers]=BrainVisionRDA.ReadData(recorder,properties);

                                % Check the block for buffer overflow,
                                %   invalidate all current data
                                if index_block~=-1 && header_data.block>index_block+1
                                    data_last_second=data_last_second+nan;
                                end
                                index_block=header_data.block;

                                % Identify markers, if any
                                %
                                % Note that marker position is indexed from 0, not 1
                                %   Based on an experimental test, the range of
                                %   position values is from 0 to 99.
                                %
                                % We are looking for a description 'R128' on channel -1
                                %
                                % There are no other markers in the data
                                %
                                for m=1:header_data.markerCount
                                    unprocessed_triggers(end+1)=markers(m).position;
                                end

                                % Process data
                                data_block=reshape(data,properties.channelCount,length(data)/properties.channelCount);
                                tmp=size(data_block,2);

                                % Retain last second of data
                                data_last_second=[data_last_second(:,tmp+1:end) data_block];

                                % Move triggers back in time...
                                unprocessed_triggers=unprocessed_triggers-tmp;

                                % For each unprocessed trigger, if it is old enough,
                                % clear it (old enough means that there is enough data
                                % after the trigger).
                                for i=1:length(unprocessed_triggers)
                                    if unprocessed_triggers(i)<-1750
                                        data_tmp=data_last_second(:,unprocessed_triggers(i)+end+(-1000:1750));
                                        send(queue,data_tmp);
                                        unprocessed_triggers(i)=1;
                                    end
                                end
                                unprocessed_triggers(unprocessed_triggers>0)=[];

                            case 3       % Receive a stop message from the ExG
                                data=pnet(recorder,'read',header.size-header_size);
                                finish=true;

                            otherwise    % Ignore any other type of data, clear them from the buffer, and continue
                                data=pnet(recorder,'read',header.size-header_size);
                        end
                        data1=pnet(recorder,'read', header_size,'byte','network','view','noblock');
                    end
                catch
                    finish=true;
                end
            end

            % Close all open socket connections
            pnet('closeall');
        end
        
        function [header,data,markers]=ReadData(connection,properties)
            %READDATA Reads signal from the ExG
            %
            % connection       TCP/IP connection object    
            % properties       ExG properties

            header=struct('block',[],'points',[],'markerCount',[]);
            header.block=swapbytes(pnet(connection,'read',1,'uint32','network'));
            header.points=swapbytes(pnet(connection,'read',1,'uint32','network'));
            header.markerCount=swapbytes(pnet(connection,'read',1,'uint32','network'));

            data=swapbytes(pnet(connection,'read',properties.channelCount*header.points,'single','network'));

            % Read markers into a struct
            markers=struct('size',[],'position',[],'points',[],'channel',[],'type',[],'description',[]);
            for m=1:header.markerCount
                marker=struct('size',[],'position',[],'points',[],'channel',[],'type',[],'description',[]);
                marker.size=swapbytes(pnet(connection,'read',1,'uint32','network'));
                marker.position=swapbytes(pnet(connection,'read',1,'uint32','network'));
                marker.points=swapbytes(pnet(connection,'read',1,'uint32','network'));
                marker.channel=swapbytes(pnet(connection,'read',1,'int32','network'));

                % Marker type is a zero-terminated array (arbitrary length)
                % Marker description is a zero-terminated array (arbitrary length)
                %
                % The BrainVision example code reads these very inefficiently, but we
                % can do much better with some string manipulation.
                tmp=strsplit(pnet(connection,'read',marker.size-16),'\0');
                marker.type=tmp{1};
                marker.description=tmp{2};

                % Store the marker
                markers(m)=marker;  
            end
        end

    end
end
