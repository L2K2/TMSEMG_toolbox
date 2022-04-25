classdef MEP
    %MEP contains filters and diagnostics for TMS evoked MEPs
    %
    % MEP properties:
    %   No public properties.
    %
    % MEP methods:
    %   y=filter(x) - Filters raw EMG data block of size [N 2751], fs=5000
    %   c=identify(y) - Identifies MEP responses from filtered data.
    %
    % Author Lari Koponen
    % Version 2022-04-25
   
    properties(Access=private)
        
        % Line-noise filter
        inds_pedestal
        X
        X_pedestal
        
        % TMS-artefact filter
        inds_artefact
        inds_prestimulus_last
        inds_poststimulus
        inds_poststimulus_first
        N_filter
        
        % Properties for MEP detection
        inds_MEP
        inds_preactivation
        V_MEP
        V_preactivation

    end
    
    methods
        function obj=MEP()
            %MEP creates the kernels for the filter operations
            %
            % Author Lari Koponen
            % Version 2021-04-29
            
            % Time samples from -200 to 350 ms, to give valid data from
            % -100 to 250 ms around the pulse.
            time=0.2*(-1000:1750);
            
            % A window for the line noise filter
            %
            % The filter window is selected to be the visible pre-stimulus
            % window. This is to avoid a large MEP causing the line-noise
            % projection to fail due to fitting the MEP and not the noise.
            % Finally, the window from -200 ms to -4 ms has the drawback
            % that strong preactivation (that is not visible to the user)
            % can cause similar 'failed' fit. With the fit to just the
            % visible pre-stimulus window, we at least have a visible cue
            % to this failure (and in any case, a reason to reject the
            % trial even if it would not be noisy). 
            obj.inds_pedestal=((time>=-105)&(time<=-5));

            frequency=60;
            time_pedestal=time(obj.inds_pedestal);
            X=[ones(size(time))' time'./max(abs(time))];
            X_pedestal=[ones(size(time_pedestal))' time_pedestal'./max(abs(time))];
            for j=1:2:3
                X=[X cos(2*pi*j*frequency*1e-3*time')];
                X_pedestal=[X_pedestal cos(2*pi*j*frequency*1e-3*time_pedestal')];
            end
            for j=1:2:3
                X=[X sin(2*pi*j*frequency*1e-3*time')];
                X_pedestal=[X_pedestal sin(2*pi*j*frequency*1e-3*time_pedestal')];
            end
            obj.X=X;
            obj.X_pedestal=X_pedestal;

            % TMS-pulse artefact
            obj.inds_artefact=abs(time)<5;
            obj.inds_prestimulus_last=find(time<=-5,1,'last');
            obj.inds_poststimulus=(time>=5);
            obj.inds_poststimulus_first=find(obj.inds_poststimulus,1);
            obj.N_filter=94; % This corresponds to high pass at 20 Hz
            
            % Window for MEP detection and for preactivation detection
            obj.inds_MEP=(time>=10)&(time<=90);
            obj.inds_preactivation=(time>=-100)&(time<=-10);
            obj.V_MEP=50;
            obj.V_preactivation=50;
            
        end
        
        function y=filter(obj,x)
            %FILTER filters the raw EMG signal
            %
            %   TMS-pulse artefact suppression.
            %
            %   Remove line noise (acausal, outside window of interest).
            %
            %   Suppress the TMS-pulse artefact.
            %
            %   High-pass filter, causal
            %
            %   De-mean the data to a pre-pulse baseline.
            %
            % Author Lari Koponen
            % Version 2022-04-25
            
            % Check that there is correct number of time points
            assert(size(x,2)==2751,'EMG data must be an N by 2751 array.');
            
            % For each channel in data, filter
            y=x;
            for i=1:size(x,1)
                % Select i'th channel
                v=x(i,:);
                % Fit and remove line frequency and its odd harmonics
                v_pedestal=(obj.X*(obj.X_pedestal\v(obj.inds_pedestal)'))';
                v=v-v_pedestal;
                % Remove TMS pulse artefact by (low pass) interpolation
                v(obj.inds_poststimulus)=v(obj.inds_poststimulus)-v(obj.inds_poststimulus_first);
                v(obj.inds_artefact)=0;
                % Store
                y(i,:)=v;
            end
            % Low-pass filter the data to extract an MEP free data
            y_LP=zeros(size(x));
            for i=1:obj.inds_prestimulus_last
                dist=min([obj.N_filter,i-1,obj.inds_prestimulus_last-i]);
                y_LP(:,i)=mean(y(:,i+(-dist:dist)),2);
            end
            for i=obj.inds_poststimulus_first:2751
                dist=min([obj.N_filter,i-obj.inds_poststimulus_first,2751-i]);
                y_LP(:,i)=mean(y(:,i+(-dist:dist)),2);
            end
            % Substract this from data to remove the polarization artefact
            y=y-y_LP;
        end
        
        function y=identify(obj,x)
            %IDENTIFY indentifies MEP responses
            %
            % y = IDENTIFY(x)
            %
            % x = [N 2751] data matrix of filtered data
            %
            % y = [N 2] data matrix
            %   The first column contains the MEP amplitudes.
            %   The second column contains trinary category:
            %       1 = MEP
            %       0 = no MEP
            %      -1 = rejected trial, due to noise or preactivation
            %
            %
            % Author Lari Koponen
            % Version 2021-04-21
            
            MEP=max(x(:,obj.inds_MEP),[],2)-min(x(:,obj.inds_MEP),[],2);
            preactivation=max(x(:,obj.inds_preactivation),[],2)-min(x(:,obj.inds_preactivation),[],2);
            
            % Measure MEP amplitude, classify to MEP or no MEP
            y=[MEP (MEP>=obj.V_MEP)];
            % Reject trials with preactivation
            y(preactivation>=obj.V_preactivation,2)=-1;
        end
    end
end

