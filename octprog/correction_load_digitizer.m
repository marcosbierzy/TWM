function [] = correction_load_digitizer(minf, meas, rep_id, group_id)
% TWM: Loader of the digitizer corrections.
%
% Parameters:
%   minf - loaded measurement header file (info-strings)
%   meas - loaded measurement
%   rep_id              - measurement repetition id
%   group_id            - measurement group id
%
% Returns:
%
% This is part of the TWM - TracePQM WattMeter.
% (c) 2017, Stanislav Maslan, smaslan@cmi.cz
% The script is distributed under MIT license, https://opensource.org/licenses/MIT.                
% 

    % measurement's root folder:
    meas_root = meas.meas_folder;

    % get relative path to the digitizer corrections:
    cor_name = infogettext(minf, 'digitizer path', {'corrections'});
    
    % build absolute path to the corrections:
    cor_path = [meas_root filesep() cor_name];
    
    % digitizer correction root folder
    cor_root = fileparts(cor_path);
    
    % load corrections info file:
    dinf = infoload(cor_path);
    
    % check correction file validity:
    tic()
    ctype = infogettext(dinf, 'type');
    toc()
    if ~strcmpi(ctype,'digitizer')
        error(sprintf('Digitizer correction loader: Invalid correction type ''%s''!',ctype));
    end
    
    % load list of the digitizer's channel names from the correction file:
    chn_names = infogetmatrixstr(dinf, 'channel identifiers');
    
    % check if the correction file matches to the measurement header instruments:
    if ~all(strcmpi(chn_names,meas.channel_names))
        error('Digitizer correction loader: Instrument''s channel names in the correction file and measurement header do not match! This correction file cannot be used for this measurement.');
    end
        
    % load channel correction paths:
    chn_paths = infogetmatrixstr(dinf, 'channel correction paths');
    % check consistency:
    if numel(chn_paths) ~= numel(chn_names)
        error('Digitizer correction loader: Number of digitizer''s channels does not match.');
    end
        
    % --- try to load interchannel timeshifts
    table_cfg = struct();
    table_cfg.primary_ax = '';
    table_cfg.second_ax = 'chn';
    table_cfg.quant_names = {'its','u_its'};
    table_cfg.default = {[1:meas.channels_count],zeros(1,meas.channels_count),zeros(1,meas.channels_count)};
    time_shifts = correction_parse_section(meas_root, dinf, minf, 'interchannel timeshift', table_cfg, 1, rep_id, group_id);

    % --- LOAD CHANNEL CORRECTIONS ---
    for c = 1:meas.channels_count
        % for each channel:
        
        % build path to channel's correction file
        channel_path = [cor_root filesep() chn_paths{c}];
        
        % load channel correction file
        cinf = infoload(channel_path);
        
        % check the file format mark
        ctype = infogettext(cinf, 'type');
        if ~strcmpi(ctype,'channel')
            error(sprintf('Digitizer correction loader: channel correction ''%s'' has invalid type!',chn_paths{c}));    
        end
        
        % check the channel identifier match (optional feature, leave empty or remove to ignore):
        % if there is 'channel identifier' item, its value must match
        % the channel descriptor value from the measurement header
        chn_name = '';
        try
            chn_name = infogettext(cinf, 'channel identifier');
        end
        if ~isempty(chn_name) && ~strcmpi(chn_name,chn_names{c})
            error(sprintf('Digitizer correction loader: Channel correction for channel ''%s'' has different channel name identifier (''%s'')!',chn_names{c},chn_name));
        end
        
        
        
        % --- try to load nominal gain
        table_cfg = struct();
        table_cfg.quant_names = {'gain','u_gain'};
        table_cfg.default = {1.0,0.0};
        nom_gain = correction_parse_section(meas_root, dinf, minf, 'nominal gain', table_cfg, 1, rep_id, group_id);
        
        % --- try to load gain transfer
        table_cfg = struct();
        table_cfg.primary_ax = 'f';
        table_cfg.second_ax = 'amp';
        table_cfg.quant_names = {'gain','u_gain'};
        table_cfg.default = {[],[],1.0,0.0};
        tfer_gain = correction_parse_section(meas_root, dinf, minf, 'gain transfer', table_cfg, 1, rep_id, group_id);
        
        % --- try to load phase transfer
        table_cfg = struct();
        table_cfg.primary_ax = 'f';
        table_cfg.second_ax = 'amp';
        table_cfg.quant_names = {'phi','u_phi'};
        table_cfg.default = {[],[],0.0,0.0};
        tfer_phi = correction_parse_section(meas_root, dinf, minf, 'phase transfer', table_cfg, 1, rep_id, group_id);
        
        % --- try to load input admittance
        table_cfg = struct();
        table_cfg.primary_ax = 'f';
        table_cfg.quant_names = {'Cp','Gp','u_Cp','u_Gp'};
        table_cfg.default = {[],0.0,0.0,0.0,0.0};
        inp_y = correction_parse_section(meas_root, dinf, minf, 'input admittance', table_cfg, 1, rep_id, group_id);

    end

end