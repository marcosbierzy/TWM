function dataout = alg_wrapper(datain, calcset)
% Part of QWTB. Wrapper script for algorithm TWM-PWRTDI.
%
% See also qwtb
%
% Format input data --------------------------- %<<<1
         
    
    % Restore orientations of the input vectors to originals (before passing via QWTB)
    % This is critical for the correction data! 
    [datain,cfg] = qwtb_restore_twm_input_dims(datain,1);
        
    % try to obtain sampling rate from alternative input quantities [Hz]
    if isfield(datain, 'fs')
        fs = datain.fs.v;
    elseif isfield(datain, 'Ts')
        fs = 1/datain.Ts.v;
    else
        fs = 1/mean(diff(datain.t.v));
    end
    
    % AC coupling mode:
    %  exclude DC components of U/I
    is_ac = isfield(datain,'ac_coupling') && datain.ac_coupling.v;         
         
    if cfg.u_is_diff || cfg.i_is_diff
        % Input data 'y' is differential: if it is not allowed, put error message here
        %error('Differential input data ''y'' not allowed!');     
    end
    
    if cfg.is_multi
        % Input data 'y' contains more than one record: if it is not allowed, put error message here
        error('Multiple input records in ''y'' not allowed!'); 
    end
    
    if mod(size(datain.u.v,1),2)
        % samples count not multiple of 2!
        if calcset.verbose
            warning('Cropping waveform to size of multiple of two.');
        end
        
        % crop to proper length: 
        datain.u.v = datain.u.v(1:end-1);
        datain.i.v = datain.i.v(1:end-1);
        if cfg.u_is_diff
            datain.u_lo.v = datain.u_lo.v(1:end-1);
        end
        if cfg.i_is_diff
            datain.i_lo.v = datain.i_lo.v(1:end-1);
        end
        
    end
    
    
    
    % Rebuild TWM style correction tables:
    % This is not necessary, but the TWM style tables are more comfortable to use then raw correction matrices
    tab = qwtb_restore_correction_tables(datain,cfg);
    
    
    
    % --------------------------------------------------------------------
    % RMS power calculation using time-domain-integration (TDI) of 
    % windowed u/i signals.    
    % Frequency dependent corrections of the gain/phase are made using
    % FFT filtering. The filtering method is based on the JV's 
    % sampling wattmeter.
    %
    % TODO:
    %  - uncertainty estimation
    %    
    
    
    % --- For easier processing we convert u/i channels to virtual channels array ---
    % so we can process the voltage and current using the same code...   
        
    % list of involved correction tables without 'u_' or 'i_' prefices
    tab_list = {'tr_gain','tr_phi','tr_Zca','tr_Yca','tr_Zcal','tr_Zcam','adc_Yin','lo_adc_Yin','Zcb','Ycb','tr_Zlo','adc_gain','adc_phi','lo_adc_gain','lo_adc_phi','tr_sfdr','adc_sfdr','lo_adc_sfdr'};
    clear vcl; id = 0; % virt. chn. list     
    % -- build virtual channel (U):
    id = id + 1;
    vcl{id}.tran = 'rvd';
    vcl{id}.name = 'u'; 
    vcl{id}.is_diff = cfg.u_is_diff;
    vcl{id}.y = datain.u.v;
    vcl{id}.ap_corr = datain.u_adc_aper_corr.v;
    if cfg.u_is_diff
        vcl{id}.y_lo = datain.u_lo.v;
        vcl{id}.tsh_lo = datain.u_time_shift_lo; % low-high side channel time shift
        vcl{id}.ap_corr_lo = datain.u_lo_adc_aper_corr.v;    
    end        
    vcl{id}.tab = conv_vchn_tabs(tab,'u',tab_list);       
    vcl{id}.tsh = 0; % high-side channel shift (do not change!)    
    % -- build virtual channel (I):
    id = id + 1;
    vcl{id}.tran = 'shunt';
    vcl{id}.name = 'i';
    vcl{id}.is_diff = cfg.i_is_diff;
    vcl{id}.y = datain.i.v;
    vcl{id}.ap_corr = datain.i_adc_aper_corr.v;
    if cfg.i_is_diff
        vcl{id}.y_lo = datain.i_lo.v;
        vcl{id}.tsh_lo = datain.i_time_shift_lo;
        vcl{id}.ap_corr_lo = datain.i_lo_adc_aper_corr.v;
    end            
    vcl{id}.tab = conv_vchn_tabs(tab,'i',tab_list);    
    vcl{id}.tsh = 0; % high-side channel shift (do not change!)
    

    % corrections interpolation mode:
    i_mode = 'pchip';
    
    % samples count:
    N = size(datain.u.v,1);    

    % size of the FFT filter:
    %  note: should be selected automatically based on the source samples count
    fft_size = 2^nextpow2(N/4);
    
    
    
    % --- Pre-processing ---
    
    % get used window parameters:
    %  get window:
    w = reshape(window_coeff('flattop_248D',N),[N 1]);
    %  get window scaling factor:
    w_gain = mean(w);
    %  get window rms:
    w_rms = mean(w.^2).^0.5;
         
    % --- get channel spectra:    
    % for each virtual (u/i) channel:
    for k = 1:numel(vcl)
        % get channel:
        vc = vcl{k};
        
        % estimate DC offset of channel:       
        vc.dc = mean(vc.y.*w)./w_gain;
        % remove it from signal:
        vc.y = vc.y - vc.dc;
        
        % get spectrum:
        [fh, vc.Y, vc.ph] = ampphspectrum(vc.y, fs, 0, 0, 'flattop_248D', [], 0);
        
        % return DC back into spectrum:
        %  note: this is workaround to eliminate leakage of the DC component into nearby DFT bins:
        %        it changes total energy/rms of the signal but since DC is limited to few percent of dominant component it should do no harm
        %        but restoring it is necessary to make the corrections work!
        vc.Y(1) = vc.dc;
        
        Y_tmp = vc.Y;
        
        if vc.is_diff
            
            % estimate DC offset of channel:       
            vc.dc_lo = mean(vc.y_lo.*w)./w_gain;
            % remove it from signal:
            vc.y_lo = vc.y_lo - vc.dc_lo;
            
            % get low-side spectrum:
            [fh, vc.Y_lo, vc.ph_lo] = ampphspectrum(vc.y_lo, fs, 0, 0, 'flattop_248D', [], 0);
            
            % return DC back into spectrum:
            vc.Y_lo(1) = vc.dc_lo;
            
        end
        
        vcl{k} = vc;
    end
    fh = fh(:);
        
    
    
    
    
    % --- Process the channels with corrections ---
    % note: this secion just calculates correction values in freq. domain
    %       the actual correction of the time-domain signal follows in next section
        
    % get ADC aperture value [s]:
    ta = abs(datain.adc_aper.v);
    
    % calculate aperture gain/phase correction (for f0):
    fap = fh + 1e-12;
    ap_gain = (pi*ta*fap)./sin(pi*ta*fap);
    ap_phi  =  pi*ta*fh; % phase is not needed - should be identical for all channels
             
    
    % --- for each virtual (u/i) channel:
    for k = 1:numel(vcl)
        % get channel:
        vc = vcl{k};
        
        % current channel?
        is_current = strcmpi(vc.tran,'shunt');
        
        % get gain/phase correction for the freq. components (high-side ADC):
        ag = correction_interp_table(vc.tab.adc_gain, vc.Y, fh, 'f',1, i_mode);
        ap = correction_interp_table(vc.tab.adc_phi,  vc.Y, fh, 'f',1, i_mode);
        
        if any(isnan(ag.gain))
            error('High-side ADC gain correction: not sufficient range of correction data!');
        end
        if any(isnan(ap.phi))
            error('High-side ADC phase correction: not sufficient range of correction data!');
        end
        
        % apply aperture corrections (when enabled and some non-zero value entered for the aperture time):
        if vc.ap_corr && ta > 1e-12
            ag.gain = ag.gain.*ap_gain;
        end
        
        if is_current
            % current channel:
            
            % add (i-u) channel timeshift correction:
            ap.phi   = ap.phi - datain.time_shift.v.*fh*2*pi; 
            ap.u_phi = (ap.u_phi.^2 + (datain.time_shift.u.*fh*2*pi).^2).^0.5;            
        end
            
         
        % apply high-side adc tfer to the spectrum estimate:        
        vc.Y  = vc.Y.*ag.gain;
        vc.ph = vc.ph + ap.phi;
        vc.Y_hi = vc.Y; % temp. high-side
        
        
        % store high-side ADC tfer:
        vc.adc_gain = ag;
        vc.adc_phi = ap;
        
        % obtain ADC LSB value:
        vc.lsb = adc_get_lsb(datain,[vc.name '_']);
        % apply ADC gain to it:
        vc.lsb = vc.lsb.*ag.gain.*ap_gain;
        
         
        
        if vc.is_diff
            % -- differential mode:
        
            % get gain/phase correction for the freq. components (low-side ADC):
            agl = correction_interp_table(vc.tab.lo_adc_gain, vc.Y_lo, fh, 'f',1, i_mode);
            apl = correction_interp_table(vc.tab.lo_adc_phi,  vc.Y_lo, fh, 'f',1, i_mode);
            
            if any(isnan(agl.gain))
                error('Low-side ADC gain correction: not sufficient range of correction data!');
            end
            if any(isnan(apl.phi))
                error('Low-side ADC phase correction: not sufficient range of correction data!');
            end              
            
            % apply aperture corrections (when enabled and some non-zero value entered for the aperture time):
            if vc.ap_corr && ta > 1e-12
                agl.gain = agl.gain.*ap_gain;
            end
            
            % apply low-side time shift correction:
            apl.phi   = apl.phi + vc.tsh_lo.v*fh*2*pi;
            apl.u_phi = (apl.u_phi.^2 + (vc.tsh_lo.u*fh*2*pi).^2).^0.5;
            
            if is_current
                % current channel:
                
                % add (i-u) channel timeshift correction:
                apl.phi   = apl.phi - datain.time_shift.v.*fh*2*pi; 
                apl.u_phi = (apl.u_phi.^2 + (datain.time_shift.u.*fh*2*pi).^2).^0.5;            
            end
            
            % apply low-side adc tfer to the spectrum estimate:        
            vc.Y_lo  = vc.Y_lo.*agl.gain;
            vc.ph_lo = vc.ph_lo + apl.phi;
            
            % store low-side ADC tfer:
            vc.adc_gain_lo = agl;
            vc.adc_phi_lo = apl;
            
            % obtain ADC LSB value for low-side:
            vc.lsb_lo = adc_get_lsb(datain,[vc.name '_lo_']);
            % apply ADC gain to it:
            vc.lsb_lo = vc.lsb_lo.*agl.gain.*ap_gain;
                        
            
            % estimate transducer correction tfer from the spectrum estimates:
            % note: The transfer is aproximated from windowed-FFT bins 
            %       despite the sampling was is coherent.
            %       The absolute values of the DFT bin vectors are wrong
            %       due to the window effects, but the ratio of the high/low-side vectors
            %       is unaffected (hopefully), so they can be used to calculate the tfer
            %       which is then normalized to the used difference of high-low side spectra.
            % note: the corrections is relative correction to the difference of digitizer voltages (y - y_lo)
            % note: using window gain so the rms of signal is correct
            % high-side:            
              Y  = vc.Y.*exp(j*vc.ph)*w_gain;
            u_Y  = vc.Y.*(ag.u_gain./ag.gain);
            u_ph = ap.u_phi;
            % low-side:
              Y_lo  = vc.Y_lo.*exp(j*vc.ph_lo)*w_gain;
            u_Y_lo  = vc.Y.*(agl.u_gain./agl.gain);
            u_ph_lo = apl.u_phi;
            % calculate transducer tfer:
            [trg,trp,u_trg,u_trp] = correction_transducer_loading(vc.tab,vc.tran,fh,[], abs(Y),angle(Y),u_Y,u_ph, abs(Y_lo),angle(Y_lo),u_Y_lo,u_ph_lo);
            % store relative tfer:
            %vc.tr_gain = trg./abs(Y - Y_lo);
            %vc.tr_phi  = trp - angle(Y - Y_lo);
            %vc.u_tr_gain = u_trg./abs(Y - Y_lo);
            %vc.u_tr_phi = u_trp;
            
            %semilogx(fh,trg)
            
            % combine ADC and transducer tfers:
            %  note: so we will apply just one filter instead of two
            vc.tr_gain = trg./abs(Y - Y_lo);
            tr_phi = trp - angle(Y - Y_lo);
            vc.adc_gain.gain = vc.adc_gain.gain.*vc.tr_gain;                                                                                  
            vc.adc_phi.phi   = vc.adc_phi.phi + tr_phi;                                 
            vc.adc_gain_lo.gain = vc.adc_gain_lo.gain.*vc.tr_gain;                                                                                  
            vc.adc_phi_lo.phi   = vc.adc_phi_lo.phi + tr_phi;
            
            % calculate effective differential LSB value:            
            vc.lsb = (vc.lsb.^2 + vc.lsb_lo.^2).^0.5.*vc.tr_gain;
           
                        
            % store differential signal spectrum estimate after the correction:
            %  i.e. this is now equivalent of single-ended channel spectrum 
            vc.Y = trg/w_gain;
            vc.ph = trp;
            vc.u_Y = u_trg/w_gain;
            vc.u_ph = u_trp;

        else
            % -- single-ended mode:
            
            % estimate transducer correction tfer from the spectrum estimate:            
            zz = zeros(size(vc.Y));
            Y = vc.Y*w_gain;
            u_Y = Y.*(ag.u_gain./ag.gain);
            u_ph = ap.u_phi;
            [trg,trp,u_trg,u_trp] = correction_transducer_loading(vc.tab,vc.tran,fh,[], Y,zz,u_Y,u_ph);
            Y = max(Y,eps); % to prevent div-by-zero
            trg = trg./Y;
            u_trg = u_trg./Y;
                        
            %semilogx(fh,vc.adc_phi.phi)
            %semilogx(fh,vc.adc_gain.gain)
            %semilogx(fh,trp)
            %semilogx(fh,trg)
            
            % combine ADC and transducer tfers:
            %  note: so we will apply just one filter instead of two            
            vc.adc_gain.gain = vc.adc_gain.gain.*trg;                                                                                  
            vc.adc_phi.phi   = vc.adc_phi.phi + trp;
            %vc.adc_gain.u_gain = vc.adc_gain.gain.*u_trg; % note the uncertainty from the ADC correction is already part of u_trg, so override ADC unc
            %vc.adc_phi.u_phi = u_trp; % note the uncertainty from the ADC correction is already part of u_trp, so override ADC unc
            
            % apply tfer to LSB:
            vc.lsb = vc.lsb.*trg;
            
            % apply transducer tfer to the spectrum estimate: 
            vc.u_Y = vc.Y.*u_trg;
            vc.u_ph = u_trp;
            vc.Y = vc.Y.*trg;
            vc.ph = vc.ph + trp;
            
            % store transducer gain:
            vc.tr_gain = trg;
                        
        end
        
        if any(isnan(trg))
            error('Transducer gain correction: not sufficient range of correction data!');                
        end
        if any(isnan(trp))
            error('Transducer phase correction: not sufficient range of correction data!');
        end
                
        vcl{k} = vc;
    end
        
    
    
    
    
    
    
    % --- Calculate uncertainty ---
    
    % window half-width:
    w_size = 12;
    
    % return spectra of the corrected waveforms:   
    Uh = vcl{1}.Y;
    Ih = vcl{2}.Y;
    ph = vcl{2}.ph - vcl{1}.ph;
    u_Uh = vcl{1}.u_Y;
    u_Ih = vcl{2}.u_Y;
    u_ph = (vcl{1}.u_ph.^2 + vcl{2}.u_ph.^2).^0.5;
    N = numel(Uh);

    
    % find dominant voltage component (assuming voltage harmonic is always there, current may not depending on the load):
    [v,idu] = max(Uh);
    
    % max. analyzed harmonics (for noise estimate):
    h_max = 100;
    
    % max. analyzed harmonics (for uncertainty components):
    h_max_proc = min(h_max,10);
    
    % not processed DFT bins:
    msk = [idu:N-3];
    
    % identify harmonic/interharmonic components:
    h_list = [];
    for h = 1:h_max
        
        % look for highest harmonic:
        [v,id] = max(Uh(msk));        
        hid = msk(id);
        
        % found harmonics list:
        h_list(h) = hid;
        
        % DFT bins occupied by the harmonic
        h_bins = max((msk(id) - w_size),1):min(msk(id) + w_size,N);
        
        % remove harmonic bins from remaining list:
        msk = setdiff(msk,h_bins);
        msk = msk(msk <= N & msk > 0);
        
    end
    H = numel(h_list);
    H = min(H,h_max_proc);
    
    % build list of relevant harmonics:
    fx = fh(h_list);
    Ux = Uh(h_list);
    Ix = Ih(h_list);
    Sx = (0.5*Ux.*Ix);
    phx = ph(h_list);
    u_Ux = u_Uh(h_list);
    u_Ix = u_Ih(h_list);
    u_phx = u_ph(h_list);
    Ux_lsb = vcl{1}.lsb(h_list);
    Ix_lsb = vcl{2}.lsb(h_list);
    
    % estimate basic parameters from spectrum):
    U_rms = sum(0.5*Uh.^2)^0.5/w_rms*w_gain;
    I_rms = sum(0.5*Ih.^2)^0.5/w_rms*w_gain;
    P = sum((0.5*Ux.*Ix.*cos(phx)));
    S = sum((0.5*Ux.*Ix));
    
    % estimate noise levels for the removed harmonics components:
    Uns = interp1(fh(msk),Uh(msk),fh,'nearest','extrap');
    Ins = interp1(fh(msk),Ih(msk),fh,'nearest','extrap');
    
    % estimate RMS noise from windowed spectrum:
    U_noise = sum(0.5*Uns.^2)^0.5/w_rms*w_gain;
    I_noise = sum(0.5*Ins.^2)^0.5/w_rms*w_gain;
    
    % calculate bits per harmonic pk-pk range:
    Ux_bits = log2(Ux./Ux_lsb);
    Ix_bits = log2(Ix./Ix_lsb);
    
    
    if strcmpi(calcset.unc,'guf')
        % --- uncertainty estimator:
            
        % -- estimate FFT filter intruduced errors:
        % voltage channel:
        ff = vcl{1}.adc_gain.f;
        fg = vcl{1}.adc_gain.gain;
        fp = vcl{1}.adc_phi.phi;
        [u_fg_U,u_fp_U] = td_fft_filter_unc(fs, numel(datain.u.v), fft_size, ff,fg,fp, i_mode, fx(1:H),Ux(1:H));    
        
        % current channel:
        ff = vcl{2}.adc_gain.f;
        fg = vcl{2}.adc_gain.gain;
        fp = vcl{2}.adc_phi.phi;
        [u_fg_I,u_fp_I] = td_fft_filter_unc(fs, numel(datain.u.v), fft_size, ff,fg,fp, i_mode, fx(1:H),Ux(1:H));
        
        % expand harmonic uncertainties by FFT filter contribution:
        u_Ux(1:H) = (u_Ux(1:H).^2 + u_fg_U.^2).^0.5;
        u_Ix(1:H) = (u_Ix(1:H).^2 + u_fg_I.^2).^0.5;
        u_phx(1:H) = (u_phx(1:H).^2 + u_fp_U.^2 + u_fp_I.^2).^0.5;
              
        
        % -- estimate SFDR uncertainty:
        % harmonic spurrs of dominant component:
        %  ###todo: maybe it would be more correct to calculate spurrs of each harmonic.. 
        f_spurr(:,1) = (fx(1)*2):fx(1):fs/2;
            
        % store estimated rms levels: 
        vcl{1}.rms = U_rms;
        vcl{2}.rms = I_rms;
        vcl{1}.Y0 = Ux(1);
        vcl{2}.Y0 = Ix(1);
            
        for k = 1:numel(vcl)
            % get v.channel
            vc = vcl{k};
            
            % transducer SFDR of dominant component only:
            tr_sfdr = correction_interp_table(vc.tab.tr_sfdr, vc.rms, fx(1), 'f',1, i_mode);
            
            % transducer spurr value:
            tr_spurr = vc.Y0*10^(-tr_sfdr.sfdr/20);
            
            % high-side ADC amplitude of dominant component: 
            amp_hi = vc.Y_hi(h_list(1));
            
            % high-side ADC SFDR for dominant component only:
            adc_sfdr = correction_interp_table(vc.tab.adc_sfdr, amp_hi, fx(1), 'f',1, i_mode);
            
            if vc.is_diff
                % -- differential mode:
                
                % low-side ADC amplitude of dominant component: 
                amp_lo = vc.Y_lo(h_list(1));
                
                % low-side ADC SFDR for dominant component only:
                adc_sfdr_lo = correction_interp_table(vc.tab.lo_adc_sfdr, amp_lo, fx(1), 'f',1, i_mode);
                
                % absolute spurr at ADC level:
                spurr = ((amp_hi*10^(-adc_sfdr.sfdr/20))^2 + (amp_lo*10^(-adc_sfdr_lo.sfdr/20))^2)^0.5;
                
                % effective differential SFDR:
                %amp_diff = Ux(1)/vc.tr_gain(h_list(1))
                %adc_sfdr = log10(spurr/(amp_diff))*20
                
            else
                % -- single-ended:
                
                % absolute spurr at ADC level:
                spurr = amp_hi*10^(-adc_sfdr.sfdr/20);
            end
                   
            % spurr harmonic bin ids in the original spectrum:
            sid = round(f_spurr*N/fs + 1);
    
            % combine ADC and transducer spurrs:
            vcl{k}.spurr = ((spurr*vc.tr_gain(sid)).^2 + (tr_spurr*ones(size(f_spurr))).^2).^0.5;                        
        end
        
        % estimate uncertainty due to the spurrs:
        u_U_sfdr = ((sum(0.5*vcl{1}.spurr.^2) + U_rms^2)^0.5 - U_rms)/3^0.5;    
        u_I_sfdr = ((sum(0.5*vcl{2}.spurr.^2) + I_rms^2)^0.5 - I_rms)/3^0.5;    
        %u_S_sfdr = S*((u_U_sfdr/U_rms)^2 + (u_I_sfdr/I_rms)^2)^0.5;
        %u_S_sfdr = sum(0.5*vcl{1}.spurr.*vcl{2}.spurr)/3^0.5;
        u_P_sfdr = sum(0.5*vcl{1}.spurr.*vcl{2}.spurr)/3^0.5;
        %u_Q_sfdr = ((S^2*u_S_sfdr^2 + P^2*u_P_sfdr^2)/(S^2 - P^2))^0.5;
        %u_PF_sfdr = ((u_P_sfdr/P)^2 + (u_S_sfdr/S)^2)^0.5;
             
        
        
        % -- estimate rms alg. single-tone uncertainty:
            
        % load single-tone wrms LUT data:
        mfld = fileparts(mfilename('fullpath'));    
        lut = load([mfld filesep() 'wrms_single_tone_unc.lut'],'-v7','lut');
        lut_st = lut.lut;
            
        % corrected signal samples count:
        M = numel(vcl{1}.y);
        
        % fundamental periods in the record:
        f0_per = fx(1)*M/fs;
        
        % samples per period of fundamental:
        fs_rat = fs/fx(1);
        
        % process all harmonics
        u_P_st = [];
        u_S_st = [];
        u_I_st = [];
        u_U_st = [];
        for h = 1:H
        
            % get U single-tone wrms uncertainty components:
            [dPx,dSx,dUx] = wrms_unc_st(lut_st, Ux(h),Ux(h), U_noise,U_noise, Ux_bits(h),Ux_bits(h), f0_per,fs_rat);
            
            % get P,S,I single-tone wrms uncertainty components:
            [dPx,dSx,dIx] = wrms_unc_st(lut_st, Ux(h),Ix(h), U_noise,I_noise, Ux_bits(h),Ix_bits(h), f0_per,fs_rat);
            
            % minimum uncertainty:
            %  ###todo: temporary, remove 
            dPx = max(dPx,0.1e-6);
            dSx = max(dSx,0.1e-6);
            dIx = max(dIx,0.1e-6);
            dUx = max(dUx,0.1e-6);
            
            % calculate absolute uncertainty of the components:
            u_P_st(h,1) = dPx.*Sx(h)/3^0.5;
            u_S_st(h,1) = dSx.*Sx(h)/3^0.5;
            u_I_st(h,1) = 2^-0.5*dIx.*Ix(h)/3^0.5;
            u_U_st(h,1) = 2^-0.5*dUx.*Ux(h)/3^0.5;
            
        end
        
        % sum component uncertainties:
        u_P_st = sum(u_P_st.^2).^0.5;
        %u_S_st = sum(u_S_st.^2).^0.5;
        %u_Q_st = ((S^2*u_S_st^2 + P^2*u_P_st^2)/(S^2 - P^2))^0.5;
        u_U_st = sum((u_U_st.*Ux(1:H)).^2).^0.5/sum((Ux(1:H).^2))^0.5;
        u_I_st = sum((u_I_st.*Ix(1:H)).^2).^0.5/sum((Ix(1:H).^2))^0.5;
        %u_I_st = sum(u_I_st.^2).^0.5;
        %u_PF_st = ((u_P_st/P)^2 + (u_S_st/S)^2)^0.5;
        
        
        
        % -- estimate rms alg. spurr uncertainty:
            
        % load single-tone wrms LUT data:
        mfld = fileparts(mfilename('fullpath'));    
        lut = load([mfld filesep() 'wrms_spurr_unc.lut'],'-v7','lut');
        lut_sp = lut.lut;
            
        
        % process all harmonics
        u_P_sp = [];
        u_S_sp = [];
        u_U_sp = [];
        u_I_sp = [];
        for h = 2:H
        
            % relative spurr position:
            f_spurr = (fx(h) - fx(1))/(fs/2 - fx(1))
            
            % get U single-tone wrms uncertainty components:
            [dPx,dSx,dUx,dIx] = wrms_unc_spurr(lut_sp, Ux(1),Ix(1), f_spurr,Ux(h),Ix(h), f0_per,fs_rat);
                    
            % calc. absolute uncertainty components:
            u_P_sp(h,1) = dPx*Sx(1)/3^0.5;
            u_S_sp(h,1) = dSx*Sx(1)/3^0.5;
            u_U_sp(h,1) = dUx*Ux(1)/3^0.5;
            u_I_sp(h,1) = dIx*Ix(1)/3^0.5;
                    
        end
        
        % sum component uncertainties:
        u_P_sp = sum(u_P_sp.^2).^0.5;
        %u_S_sp = sum(u_S_sp.^2).^0.5;
        %u_Q_sp = ((S^2*u_S_sp^2 + P^2*u_P_sp^2)/(S^2 - P^2))^0.5;
        %u_U_sp = sum(u_U_sp.^2).^0.5;
        %u_I_sp = sum(u_I_sp.^2).^0.5;    
        u_U_sp = sum((u_U_sp.*Ux(1:H)).^2).^0.5/sum((Ux(1:H).^2))^0.5;
        u_I_sp = sum((u_I_sp.*Ix(1:H)).^2).^0.5/sum((Ix(1:H).^2))^0.5;
        %u_PF_sp = ((u_P_sp/P)^2 + (u_S_sp/S)^2)^0.5;
        
    else
        % -- no uncertainty mode:
        % clear all algoreithm-itself uncertainties
        % note: the correction uncertainty stays there... 
        
        u_U_sfdr = 0;
        u_I_sfdr = 0;
        u_P_sfdr = 0;
        u_U_st = 0;
        u_I_st = 0;
        u_P_st = 0;
        u_U_sp = 0;
        u_I_sp = 0;
        u_P_sp = 0;
                
    end
    
    % estimate corrections related uncertainty from relevant harmonics:
    u_U = sum(0.5*u_Ux.^2).^0.5;
    u_I = sum(0.5*u_Ix.^2).^0.5;
    %u_S = sum((0.5*Ux.*Ix.*((u_Ux./Ux).^2 + (u_Ix./Ix).^2).^0.5).^2).^0.5;
    u_P = sum((0.5*((Ix.*cos(phx).*u_Ux).^2 + (Ux.*cos(phx).*u_Ix).^2 + (Ux.*Ix.*sin(phx).*u_phx).^2).^0.5).^2).^0.5;
    %u_Q = sum((0.5*((Ix.*sin(phx).*u_Ux).^2 + (Ux.*sin(phx).*u_Ix).^2 + (Ux.*Ix.*cos(phx).*u_phx).^2).^0.5).^2).^0.5;
    %u_PF = ((u_P./P).^2 + (u_S./S).^2).^0.5;
        
    % addup uncertainties from the algorithm itself:
    u_U = (u_U.^2 + u_U_sfdr^2 + u_U_st.^2 + u_U_sp.^2).^0.5;
    u_I = (u_I.^2 + u_I_sfdr^2 + u_I_st.^2 + u_I_sp.^2).^0.5;
    u_P = (u_P.^2 + u_P_sfdr^2 + u_P_st.^2 + u_P_sp.^2).^0.5;
    %u_S = (u_S.^2 + u_S_sfdr^2 + u_S_st.^2 + u_S_sp.^2).^0.5;
    %u_Q = (u_Q.^2 + u_Q_sfdr^2 + u_Q_st.^2 + u_Q_sp.^2).^0.5;
    %u_PF = (u_PF.^2 + u_PF_sfdr^2 + u_PF_st.^2 + u_PF_sp.^2).^0.5;
    
    
    
    
    
    harmonics = [Ux(1:H),Ix(1:H)];
    u_harmonics = [u_Ux(1:H),u_Ix(1:H)];
    noises = [U_noise,I_noise];
    
    rand_ph = rand(size(phx(1:H)))*2*pi;
        
    % make temp copy of virtual channels:
    vcp = vcl;
    for v = 1:numel(vcl)
        
        vc = vcp{v};
                        
        % save harmoncis list to synthesize:
        vc.sim.A = harmonics(:,v)./vc.adc_gain.gain(h_list(1:H));
        vc.sim.u_A = u_harmonics(:,v)./vc.adc_gain.gain(h_list(1:H));
        if vc.name == 'u'
            vc.sim.ph = phx(1:H) - vc.adc_phi.phi(h_list(1:H)) + rand_ph;
            vc.sim.u_ph = u_phx(1:H);
        else
            vc.sim.ph = rand_ph;
            vc.sim.u_ph = 0*u_phx(1:H);
        end
        % save aux parameters to synthesize:
        vc.sim.noise = noises(v)./mean(vc.adc_gain.gain);
               
        % remove useless stuff:
        vc = rmfield(vc,{'y','Y','ph','Y_hi','u_Y','u_ph'});
        vc.adc_gain = rmfield(vc.adc_gain,{'u_gain'});
        vc.adc_phi = rmfield(vc.adc_phi,{'u_phi','f'});
        if vc.is_diff
            vc = rmfield(vc,{'y_lo','Y_lo','ph_lo'});
            vc = rmfield(vc,{'adc_gain_lo','adc_phi_lo','ph_lo'});
        end
        
        % disable diff mode:
        vc.is_diff = 0;
        
        vcp{v} = vc;
    end
    
    sig.vc = vcp;    
    sig.i_mode = i_mode;
    sig.fs = fs;
    sig.fft_size = fft_size;
    sig.N = size(datain.u.v,1);
    sig.fh = fh;
    sig.is_sim = 1;
    sig.sim.fx = fx(1:H);
    % save reference values:
    sig.ref.P = P;        
    sig.ref.I = I_rms;
    sig.ref.U = U_rms;
       
    for k = 1:100
        res{k} = proc_wrms(sig);
    end
    v = vectorize_structs_elements(res);
    
    2*std(v.dU)
    2*std(v.dI)
    2*std(v.dP)
    
    
    % --- Apply the calcualted correction in the time-domain:
    % note: here we subtract phase of ref. channel from all others in order to reduces
    %       total absolute value of the phase corrections
    
    % reference channel phase (voltage, high-side):    
    ap_ref = vcl{1}.adc_phi;
       
    % for each virtual (u/i) channel:
    for k = 1:numel(vcl)
        % get v.channel:
        vc = vcl{k};
                
        % apply DC gain to DC value:
        vc.dc = vc.dc*vc.adc_gain.gain(1);
        vc.u_dc = vc.dc*vc.adc_gain.u_gain(1);                       
                
        % subtract reference channel phase:
        %  note: this is to reduce total phase correction value
        vc.adc_phi.phi   = vc.adc_phi.phi - ap_ref.phi;
        
        % apply tfer filter for high-side:
        [vc.y, a,b, ff,fg,fp] = td_fft_filter(vc.y, fs, fft_size, fh,vc.adc_gain.gain,vc.adc_phi.phi ,i_mode);
        %vc.y = vc.y(a:b);     

        
        % calculate actual phase correction made:
        adc_phi_real = interp1(ff,fp,fh,i_mode,'extrap');
        
        % phase correction uncertainty contribution:
        u_phi_corr = abs(adc_phi_real - vc.adc_phi.phi)/3^0.5;
        
        % add uncertainty to the spectrum estimate components:
        vc.u_ph = (vc.u_ph.^2 + u_phi_corr.^2).^0.5;
        
        
        %semilogx(fh,vc.adc_phi.phi)
        %semilogx(fh,vc.adc_gain.gain) 
        
        if vc.is_diff
            % -- differential mode:
            
            % apply DC gain to DC value:
            vc.dc_lo = vc.dc_lo*vc.adc_gain_lo.gain(1);
            vc.u_dc_lo = vc.dc_lo*vc.adc_gain_lo.u_gain(1);           
            
            % subtract reference channel phase:
            %  note: this is to reduce total phase correction value 
            vc.adc_phi_lo.phi   = vc.adc_phi_lo.phi - ap_ref.phi;
            
            % apply tfer filter for low-side:
            [vc.y_lo, a,b, ff,fg,fp] = td_fft_filter(vc.y_lo, fs, fft_size, fh,vc.adc_gain_lo.gain,vc.adc_phi_lo.phi, i_mode);
            
            % calculate actual phase correction made:
            adc_phi_real = interp1(ff,fp,fh,i_mode,'extrap');
            
            % phase correction uncertainty contribution:
            u_phi_corr = abs(adc_phi_real - vc.adc_phi_lo.phi)/3^0.5;
            
            % add uncertainty to the spectrum estimate components:
            vc.u_ph = (vc.u_ph.^2 + u_phi_corr.^2).^0.5;
            
            % calculate high-low-side difference:
            vc.y = vc.y - vc.y_lo;
            
            % calculate differential DC offset:
            vc.dc = vc.dc - vc.dc_lo;
            vc.u_dc = (vc.u_dc^2 + vc.u_dc_lo^2)^0.5; 
                        
        end
        
        % store v.channel:
        vcl{k} = vc;            
    end
    
    
    
    
    
    
    
    
    
    
    
    % --- Calculate power ---
    % this is the main time-domain-integration calculation 
    
    % get corrected u,i:
    u = vcl{1}.y;
    i = vcl{2}.y;
    N = numel(u);

    % generate window for the RMS algorithm (periodic):
    w = blackmanharris(N,'periodic');
    w = w(:);
    
    % calculate inverse RMS of the window (needed for scaling of the result): 
    W = mean(w.^2)^-0.5;
    
    % calculate RMS levels of u,i:
    U = W*mean((w.*u).^2).^0.5;
    I = W*mean((w.*i).^2).^0.5;
       
    % calculate RMS active power value:
    P = W^2*mean(w.^2.*u.*i);
    
    
    % add DC components (DC coupling mode only):
    if ~is_ac
        
        % obtain DC components:
        dc_u = vcl{1}.dc;
        dc_i = vcl{2}.dc;
        u_dc_u = vcl{1}.u_dc;
        u_dc_i = vcl{2}.u_dc;
        
        % add DC to results:
        U = (U^2 + dc_u^2)^0.5;
        I = (I^2 + dc_i^2)^0.5;
        P = P + dc_u*dc_i;
        
        % add DC uncertainty to the results:
        u_U = (dc_u^2*u_dc_u^2 + U^2*u_U^2)^0.5/(dc_u^2 + U^2)^0.5;
        u_I = (dc_i^2*u_dc_i^2 + I^2*u_I^2)^0.5/(dc_i^2 + I^2)^0.5;
        u_P = P*((u_P/P)^2 + (u_dc_u/dc_u)^2 + (u_dc_i/dc_i)^2)^0.5;        
    end
    
    % calculate apperent power:
    S = U*I;
    u_S = ((u_U*I)^2 + (u_I*U)^2)^0.5;        
    
    % calculate reactive power:
    Q = (S^2 - P^2)^0.5;
    u_Q = ((S^2*u_S^2 + P^2*u_P^2)/(S^2 - P^2))^0.5; % ###note: ignoring corelations, may be improved
    
    % calculate power factor:
    PF = P/S;
    u_PF = ((u_P./P).^2 + (u_S./S).^2).^0.5; % ###note: ignoring corelations, may be improved
    
    
    
        
    
    % --- return quantities to QWTB:
    
    % power parameters:
    dataout.U.v = U;
    dataout.U.u = u_U;
    dataout.I.v = I;
    dataout.I.u = u_I;
    dataout.P.v = P;
    dataout.P.u = u_P;
    dataout.S.v = S;
    dataout.S.u = u_S;
    dataout.Q.v = Q;
    dataout.Q.u = u_Q;
    dataout.PF.v = PF;
    dataout.PF.u = u_PF;
    
    % return spectra of the corrected waveforms:   
    [fh, dataout.spec_U.v] = ampphspectrum(u, fs, 0, 0, 'flattop_248D', [], 0);
    [fh, dataout.spec_I.v] = ampphspectrum(i, fs, 0, 0, 'flattop_248D', [], 0);
    dataout.spec_S.v = dataout.spec_U.v.*dataout.spec_I.v;
    dataout.spec_f.v = fh(:);
    
%       figure;
%       loglog(fh,dataout.spec_U.v)
%       figure;
%       loglog(fh,dataout.spec_I.v)  
    
    
     
    % --------------------------------------------------------------------
    % End of the demonstration algorithm.
    % --------------------------------------------------------------------
       
   
    % --- my job here is done...
          

end % function


function [lsb] = adc_get_lsb(din,pfx)
% obtain ADC resolution for channel starting with prefix 'pfx', e.g.:
% adc_get_lsb(datain,'u_lo_') will load LSB value from 'datain.u_lo_adc_lsb'
% if LSB is not found, it tries to calculate the value from bit resolution and nominal range
% 
    if isfield(din,[pfx 'adc_lsb'])
        % direct LSB value: 
        lsb = getfield(din,[pfx 'lsb']); lsb = lsb.v;
    elseif isfield(din,[pfx 'adc_bits']) && isfield(din,[pfx 'adc_nrng'])
        % LSB value from nom. range and bit resolution:
        bits = getfield(din,[pfx 'adc_bits']); bits = bits.v;
        nrng = getfield(din,[pfx 'adc_nrng']); nrng = nrng.v;        
        lsb = nrng*2^-(bits-1);        
    else
        % nope - its not there...
        error('PWDTDI algorithm: Missing ADC LSB value or ADC range and bit resolution!');
    end
end

% convert correction tables 'pfx'_list{:} to list{:}
% i.e. get rid of prefix (usually 'u_' or 'i_')
% list - names of the correction tables
% pfx - prefix without '_' 
function [tout] = conv_vchn_tabs(tin,pfx,list)
    
    tout = struct();
    for t = 1:numel(list)    
        name = [pfx '_' list{t}];
        if isfield(tin,name)
            tout = setfield(tout, list{t}, getfield(tin,name));
        end
    end
    
end





