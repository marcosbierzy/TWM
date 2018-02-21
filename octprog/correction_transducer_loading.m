function [A,ph,u_A,u_ph] = correction_transducer_loading(tab,tran,f,F_max,A,ph,u_A,u_ph,lo_A,lo_ph,u_lo_A,u_lo_ph)
% TWM: This function calculates loading effect of the transducer by the cable(s)/digitizer input
% impedance. It will take the measured voltages from the digitizer channel(s), correction data
% describing the cable(s), terminal(s) and input admittance of the digitizer(s) and will return
% input voltage (or current for shunt). It can calculate correction for both single-ended
% and differentially connected transducers (including the leakage effects via low-side connection).
% It also propagates the uncertainty of the all correction inputs to the output.
%
% Note the function is very complex and for many input freq. spots it is slow and memory demanding.
% For the reason the function calculates accurately up to 'F_max' spots. Then it switches to 
% faster approximation mode. For single-ended mode the approximation is done simply:
%  1) build temp. freq. axis with F_max spots
%  2) eval. correction for unity input amplitudes
%  3) upsample the correction to original freq. spots
%  4) apply to original inputs
% That should not introduce too much errors as long as the corrections does not contain
% some sudden steep changes.
% For differential mode the situation is more complex because the correction is function
% of two inputs (low- and high-side). Therefore, it does following:
%  1) it splits the input freq. spots to up to F_max equal groups
%  2) it identifies dominant components in each group (max diff. of A and lo_A)
%  3) it calculates the correction relative to the diff. of inputs at the identified spots
%  4) it upsamples the correction to original freq. spots
%  5) applies the correction to original inputs
%  6) it expands the uncertainty in order to estimate the errors introduced to the uncelected 
%     freq. spots
% Self test shows it works, however it may return unnecesarilly large uncertainty for 
% the unselected freq. spots.
%    
%
% Usage:
% [A,ph,u_A,u_ph] = correction_transducer_loading(tab,'shunt',[],f,A,ph,u_A,u_ph)
% [A,ph,u_A,u_ph] = correction_transducer_loading(tab,'shunt',F_max,f,A,ph,u_A,u_ph)
% [A,ph,u_A,u_ph] = correction_transducer_loading(tab,'rvd',[],f,A,ph,u_A,u_ph)
% [A,ph,u_A,u_ph] = correction_transducer_loading(tab,'rvd',F_max,f,A,ph,u_A,u_ph)
%   - single-ended transducers
%
% [A,ph,u_A,u_ph] = correction_transducer_loading(tab,'shunt',F_max,f,A,ph,u_A,u_ph,lo_A,lo_ph,lo_u_A,lo_u_ph)
% [A,ph,u_A,u_ph] = correction_transducer_loading(tab,'shunt',[],f,A,ph,u_A,u_ph,lo_A,lo_ph,lo_u_A,lo_u_ph)
% [A,ph,u_A,u_ph] = correction_transducer_loading(tab,'rvd',F_max,f,A,ph,u_A,u_ph,lo_A,lo_ph,lo_u_A,lo_u_ph)
% [A,ph,u_A,u_ph] = correction_transducer_loading(tab,'rvd',[],f,A,ph,u_A,u_ph,lo_A,lo_ph,lo_u_A,lo_u_ph)
%   - differential transducers
%
% [] = correction_transducer_loading('test')
%   - run function selftest
%
% Parameters:
%   tab     - TWM-style correction tables with items:
%             tr_gain - 2D table (freq+rms axes) of tran. absolute gain values (in/out)
%             tr_phi - 2D table (freq+rms axes) of tran. phase shifts (in/out) [rad]
%             tr_Zca - freq dep. of output terminals series Z (Rs+Ls format)              
%             tr_Yca - freq dep. of output terminals shunting Y (Cp+D format)
%             tr_Zcal - freq dep. of low-side output terminal series Z (Rs+Ls format)
%             tr_Zcam - freq dep. of mutual inductance of output terminals
%             adc_Yin - freq dep. of digitizer input admittance (Cp+Gp format)
%             lo_adc_Yin - freq dep. of digigitizer low-side channel input
%                          admittance (Cp+Gp format), differential mode only
%             Zcb - freq dep. of cable series Z (Rs+Ls format)
%             Ycb - freq dep. of cable shunting Y (Cp+D format)
%             tr_Zlo - freq dep. of RVD's low side resistor Z (Rp+Cp format)
%                      note: not used for shunts
%   tran    - transducer type {'rvd' or 'shunt'}
%   F_max   - maximum count of frequency spots for accurate calculation
%             leave empty [] for default (5000); 
%   f       - vector of frequencies for which to calculate the correction [Hz]
%   A       - vector of amplitudes at the digitizer input [V]
%   ph      - vector of phase angles at the digitizer input [rad]
%   u_A     - vector of abs. uncertainties of 'A' 
%   u_ph    - vector of abs. uncertainties of 'ph'
%   lo_A    - vector of amplitudes at the low-side digitizer input [V]
%   lo_ph   - vector of phase angles at the low-side digitizer input [rad]
%   u_lo_A  - vector of abs. uncertainties of 'lo_A' 
%   u_lo_ph - vector of abs. uncertainties of 'lo_ph'
%
% Returns:
%   A    - calculated input amplitudes [V]
%   ph   - calculated input phase shifts [rad]
%   u_A  - abs. uncertainties of 'A' 
%   u_ph - abs. uncertainties of 'ph'
%
%
%
% The correction applies following equivalent circuit (single-ended mode):
%
%  in (RVD)
%  o-------+
%          |
%         +++
%         | | Zhi
%         | |
%         +++ Zca/2      Zca/2      Zcb/2      Zcb/2
%  in      |  +----+     +----+     +----+     +----+          out
%  o-------+--+    +--+--+    +--o--+    +--+--+    +--o--+-----o
%  (shunt) |  +----+  |  +----+     +----+  |  +----+     |
%         +++        +++                   +++           +++
%         | |        | |                   | |           | |
%         | | Zlo    | | Yca               | | Ycb       | | Yin
%         +++        +++                   +++           +++
%  0V      |          |                     |             |     0V
%  o-------+----------+----------o----------+----------o--+-----o
%
%  ^                             ^                     ^        ^
%  |                             |                     |        |
%  +-------- TRANSDUCER ---------+------ CABLE --------+- ADC --+
%
% The correction consists of 3 components:
%  a) The transducer (RVD or shunt). When shunt, the Zhi nor Zlo are not
%     required as the Zlo can be expressed from tr_gain and tr_phi.
%     Part of the tran. definition is also its output terminals modeled 
%     as transmission line Zca/2-Yca-Zca/2.
%  b) Second part is optional cable from Zcb/2-Ycb-Zcb/2.
%  c) Last part is the internal shunting admittance of the digitizer's channel.
%
% The algorithm calculates the correction in 3 steps:
%  1) Unload the transducer from the Zca-Yca load.
%  2) Calculate effect of the cable and digitizer to the impedance Zlo.
%  3) Calculate complex transfer from V(Zlo) to V(out).
%  4) It calculates the input voltage or current and the uncertainties.
%
% Note the aditional parameters 'Zcal' and 'Zcam' were added for the 
% differential connection mode.  
% 
% 
%
%
% The correction applies following equivalent circuit (differential mode):
%
%  in (RVD)
%  o-------+
%          |
%         +++
%         | | Zhi                   
%         | |          
%         +++ Zca/2      Zca/2       Zcb/2      Zcb/2
%  in      |  +----+     +----+      +----+     +----+          
%  o-------+--+    +--+--+    +--o---+    +--+--+    +--o---+---o u
%  (shunt) |  +----+  |  +----+      +----+  |  +----+      |
%          |          |      ^              +++            +++
%         +++        +++      \             | |            | |
%         | |        | | Yca   | M          | | Ycb        | | Yin
%         | |        | |       |            +++            +++
%         +++        +++      /              |              |
%      Zlo |          |      v     +---------+----------o---+---o gnd_u
%  0V      |  +----+  |  +----+    | +----+     +----+
%  o-------+--+    +--+--+    +--o---+    +--+--+    +--o---+---o u_lo
%             +----+     +----+    | +----+  |  +----+      |
%             Zcal/2     Zcal/2    | Zcb/2  +++  Zcb/2     +++
%                                  |        | |            | |
%                                  |        | | Ycb        | | lo_Yin
%                                  |        +++            +++
%                                  |         |              |
%                                  +---------+----------o---+---o gnd_u_lo
%                                  |
%                                 +++                                
%  ^                             ^                      ^       ^
%  |                             |                      |       |
%  +-------- TRANSDUCER ---------+------ CABLES --------+- ADC -+
%
% The correction consists of several sections:
%  a) transducer with its terminals model (Zca, Zcal, Zcam, Yca)
%  b) cables to the digitizers (Zcb, Ycb)
%  c) digitizer shunting admittances Yin, lo_Yin
%
% 1) The solver first simplifies the cables+digitizers to following:
%  
%  in (RVD)
%  o-------+
%          |
%  +--+   +++
%  |  |   | | Zhi                       
%  |  |   | |                           Uhi
%         +++ Zca/2      Zca/2        ------->                
%  in      |  +----+     +----+        +----+                     
%  o-------+--+    +--+--+    +--o-----+    +---+
%  (shunt) |  +----+  |  +----+        +----+   |                
%  |  |    |          |  *   ^          Zih     |                
%  |  |   +++  +--+  +++      \         ----+   |                
%  |I1|   | |  |I2|  | | Yca   | Zcam    I3 |   |                     
%  |  |   | |  |  v  | |       |        <---+   |                
%  |  |   +++  +-    +++      /         Ulo     |              
%      Zlo |          |  *   v        ------->  |                         
%  0V      |  +----+  |  +----+        +----+   |         
%  o-------+--+    +--+--+    +--o-----+    +---+
%          |  +----+     +----+        +----+   |              
%  |  |   +++ Zcal/2     Zcal/2         Zil     |               
%  |  v   | |                    -----------+   |               
%  |      | |                         I4    |   |                      
%         +++ Zx (unknown)       <----------+   |             
%  GND     |                                    |              
%  o-------+------------------------------------+
%  ^       |                     ^              ^
%  |      +++                    |              |
%  +-------- TRANSDUCER ---------+-- CABLES ----+
%                                     +ADC
% 2) Unload the transducer from the Zca-Zcal-Yca+Zcam load.
% 3) It solves the circuit mesh by loop-current method to obtain currents I1 and I2.
% 4) It calculates the input voltage or current and the uncertainties.
%
%
% This is part of the TWM - TracePQM WattMeter (https://github.com/smaslan/TWM).
% (c) 2018, Stanislav Maslan, smaslan@cmi.cz
% The script is distributed under MIT license, https://opensource.org/licenses/MIT.                
%

    if ischar(tab) && strcmpi(tab,'test')
        % --- run self-test:
        correction_transducer_loading_test();
        
        A = [];
        ph = [];
        u_A = [];
        u_ph = [];
        return
        
    end
    
    % maximum freq components for full solution:
    if ~exist('F_max','var')
        F_max = 5000; % defult
    end
    
    % interpolation mode:
    int_mode = 'pchip';    

    % is it RVD?
    is_rvd = strcmpi(tran,'rvd');
    
    % differential mode?
    is_diff = nargin >= 9;
    
    % convert inputs to vertical:
    org_orient = size(f); % remember original orientation
    F = numel(f);
    f = f(:);
    f_org = f; % backup of original freq spots
    A = A(:);
    ph = ph(:);
    u_A = u_A(:);
    u_ph = u_ph(:);
    A_org = A; % backup of original freq spots
    ph_org = ph; % backup of original freq spots
    u_A_org = u_A; % backup of original freq spots
    u_ph_org = u_ph; % backup of original freq spots
    if is_diff
        lo_A = lo_A(:);
        lo_ph = lo_ph(:);
        u_lo_A = u_lo_A(:);
        u_lo_ph = u_lo_ph(:);        
        lo_A_org = lo_A; % backup of original freq spots
        lo_ph_org = lo_ph; % backup of original freq spots
        u_lo_A_org = u_lo_A; % backup of original freq spots
        u_lo_ph_org = u_lo_ph; % backup of original freq spots
    end
    
    % used frequency range:
    f_min = min(f);
    f_max = max(f);
    
    % make list of involved correction tables:
    tlist = {tab.tr_gain,tab.tr_phi,tab.tr_Zlo,tab.tr_Zca,tab.tr_Yca,tab.Zcb,tab.Ycb,tab.adc_Yin};
    if is_diff        
        tlist = {tlist{:},tab.lo_adc_Yin,tab.tr_Zcal,tab.tr_Zcam};
    end
    
    % merge axes of the tables to common range:
    [tlist,rms,fx] = correction_expand_tables(tlist);

    if ~isempty(fx) && (f_max > max(fx) || f_min < min(fx))
        error('Transducer loading correction: Some of the involved correction tables have insufficient frequency reange!');
    end
    
    if F > F_max
        % --- too much freq components - switch to interpolated/approximate solution ---
        
        if is_diff
            % --- diff mode:
            
            % identify major frequency components in the input spectrum:
            [fid,grp_size] = find_mjr_freqs(A.*exp(j*ph),lo_A.*exp(j*lo_ph),F_max);

            % create a list of the spots to analyse:
            f = f(fid);
            A = A(fid);
            ph = ph(fid);
            u_A = u_A(fid);
            u_ph = u_ph(fid);
            lo_A = lo_A(fid);
            lo_ph = lo_ph(fid);
            u_lo_A = u_lo_A(fid);
            u_lo_ph = u_lo_ph(fid);
            
        else
            % --- single-ended mode:
            
            % build new logspace freq axis with maximum spots:
            % note this will be used for the correction evaluation
            f = logspace(log10(f_min),log10(f_max),F_max).';
            
            % create a list of the spots to analyse (unity amplitudes):
            A = ones(F_max,1);
            ph = zeros(F_max,1);
            u_A = zeros(F_max,1);
            u_ph = zeros(F_max,1);
            
        end
        
    end
    % not full freq list solution flag:
    int_freq = F > F_max;
    
    % working frequency range:
    F_w = numel(f);    
    
    % total quantities (needed for the difference uncertainty evaluator):
    QT = 13;    
    
    % randomize high-side voltage and convert it to complex form:
    A_v = uncdiff(A,u_A,1,QT);
    ph_v = uncdiff(ph,u_ph,2,QT);
    U = A_v.*exp(j*ph_v);     
        
    % interpolate RVD's low side admittance:
    tmp = correction_interp_table(tab.tr_Zlo,[],f,int_mode);
    tmp2 = correction_interp_table(tab.tr_Zlo,[],f,'linear');
    [Zlo,u_Zlo] = CpRp2Z(f, tmp.Cp, tmp.Rp, tmp.u_Cp, tmp.u_Rp);
    Zlo2        = CpRp2Z(f, tmp2.Cp, tmp2.Rp, tmp2.u_Cp, tmp2.u_Rp);
    u_cint = (abs(real(Zlo) - real(Zlo2)) + j*abs(imag(Zlo) - imag(Zlo2)))/3^0.5; % estimate iterpolation error uncertainty     
    % detect envelope of the interp uncertainty:      
    if tlist{3}.size_y                
        % identify centres of the correction sections (that is where largest interpolation error is):        
        fid = interp1(f,[1:F_w],0.5*(tlist{3}.f(1:end-1) + tlist{3}.f(2:end)),'nearest');
        % override uncertainty by envelope:
        u_cint = interp1(f(fid),u_cint(fid),f,'pchip','extrap');
    end
    u_Zlo = (real(u_Zlo).^2 + real(u_cint).^2).^0.5 + j*(imag(u_Zlo).^2 + imag(u_cint).^2).^0.5;    
    Zlo = uncdiff(Zlo, u_Zlo, 3, QT);
        
    
    % interpolate output terminals Z/Y:
    tmp = correction_interp_table(tab.tr_Zca,[],f,int_mode);
    [Zca,u_Zca] = LsRs2Z(f, tmp.Ls, tmp.Rs, tmp.u_Ls, tmp.u_Rs);
    Zca = uncdiff(Zca, u_Zca, 4, QT);
    
    tmp = correction_interp_table(tab.tr_Yca,[],f,int_mode);
    [Yca,u_Yca] = CpD2Y(f, tmp.Cp, tmp.D, tmp.u_Cp, tmp.u_D);
    Yca = uncdiff(Yca, u_Yca, 5, QT);
    
    % interpolate cable's terminals Z/Y:
    tmp = correction_interp_table(tab.Zcb,[],f,int_mode);
    [Zcb,u_Zcb] = LsRs2Z(f, tmp.Ls, tmp.Rs, tmp.u_Ls, tmp.u_Rs);
    Zcb = uncdiff(Zcb, u_Zcb, 6, QT);
    
    tmp = correction_interp_table(tab.Ycb,[],f,int_mode);
    [Ycb,u_Ycb] = CpD2Y(f, tmp.Cp, tmp.D, tmp.u_Cp, tmp.u_D);
    Ycb = uncdiff(Ycb, u_Ycb, 7, QT);
    
    % interpolate ADC's input admittances:
    tmp = correction_interp_table(tab.adc_Yin,[],f,int_mode);
    [Yin,u_Yin] = CpGp2Y(f, tmp.Cp, tmp.Gp, tmp.u_Cp, tmp.u_Gp);
    Yin = uncdiff(Yin, u_Yin, 8, QT);

    
    % interpolate divider's transfer, convert to complex transfer:        
    tr_gain = correction_interp_table(tab.tr_gain,[],f,int_mode);
    tr_phi = correction_interp_table(tab.tr_phi,[],f,int_mode);            
    g_org = nanmean(tr_gain.gain,2);
    p_org = nanmean(tr_phi.phi,2);        
    tr = g_org.*exp(j*p_org); % convert to complex            
    tr = repmat(tr,[1 QT*2+1]); % expand because MATLAB < 2016b cannot broadcast so the whole calculation would be a mess of bsxfun()...
    % note the uncertainty is ignored at this point, because we don't know which 'rms' value we have yet,
    % so it will be applied at the end!                
    
    if ~is_rvd

        % calculate Zlo for SHUNT from transfer: 
        [Zlo,u_Zlo] = Z_inv(tr,0.*tr);
        
    end       
    
    if is_diff
        % =====================================
        % ========= DIFFERENTIAL MODE =========
        % =====================================   
        
        % randomize low-side voltage and convert it to complex form:
        lo_A_v = uncdiff(lo_A,u_lo_A,9,QT);
        lo_ph_v = uncdiff(lo_ph,u_lo_ph,10,QT);
        U_lo = lo_A_v.*exp(j*lo_ph_v);
                
        % --- load additional corrections:
        % interpolate output terminals Z/Y:       
        tmp = correction_interp_table(tab.tr_Zcal,[],f,int_mode);
        [Zcal,u_Zcal] = LsRs2Z(f, tmp.Ls, tmp.Rs, tmp.u_Ls, tmp.u_Rs);
        Zcal = uncdiff(Zcal, u_Zcal, 11, QT);
        
        tmp = correction_interp_table(tab.tr_Zcam,[],f,int_mode);
        [Zcam,u_Zcam] = LsRs2Z(f, tmp.M, 0.*tmp.M, tmp.u_M, 0.*tmp.M);
        Zcam = uncdiff(Zcam, u_Zcam, 12, QT);
        
        % interpolate ADC's input admittances:
        tmp = correction_interp_table(tab.lo_adc_Yin,[],f,int_mode);
        [lo_Yin,u_lo_Yin] = CpGp2Y(f, tmp.Cp, tmp.Gp, tmp.u_Cp, tmp.u_Gp);
        Yinl = uncdiff(lo_Yin, u_lo_Yin, 13, QT);
        
        
        % --- 1) Solve the cable->digitizer transfers and simplify the circuit:  
        
        % calculate transfer of the high-side cable to dig. input (in/out):
        k1 = (Yin.*Zcb + 2)./2;
        Zih = 1./(1./(1./Yin + 0.5*Zcb) + Ycb);
        k2 = (Zih + 0.5*Zcb)./Zih;
        Zih = Zih + 0.5*Zcb; % effective cable input impedance
        kih = k1.*k2; % complex cable to dig. transfer        
        
        % calculate transfer of the low-side cable to dig. input (in/out):
        k1 = (Yinl.*Zcb + 2)./2;
        Zil = 1./(1./(1./Yinl + 0.5*Zcb) + Ycb);
        k2 = (Zil + 0.5*Zcb)./Zil;
        Zil = Zil + 0.5*Zcb; % effective cable input impedance
        kil = k1.*k2; % complex cable to dig. transfer
        
        % apply high/low side cable transfers to the input complex voltages:        
        Uhi = U.*kih;  
        Ulo = U_lo.*kil;
        
                        
        % --- 2) Assume the transd. was measured including the effect of the Zca-Zcal-Zcam-Yca
        %        and no external load. So unload it from the 0.5Zca-0.5Zcal+2*Zcam-Yca load:
        
        % calculate effective terminals loop impedance (series high+low side - mutual impedance):
        %Zca_ef = Zca + Zcal - 2*Zcam;
        Zca_ef = Zca + Zcal;
        
        % actual internal Zlo impedance:
        Zlo_int = 1./(1./(Zlo - 0.5*Zca_ef) - Yca) - 0.5*Zca_ef;
        
        % effective value of Zlo with 0.5Zca-Yca in parallel:
        Zlo_ef = 1./(1./Zlo_int + 1./(1./Yca + 0.5*Zca_ef));
        
        % the complex transfer of the 0.5Zca-Yca divider (out/in):
        k_ca = 2./(Yca.*Zca_ef + 2);
        
        % actual division ratio Zhi:Zlo_ef:
        tr = tr.*k_ca;
        
        if is_rvd
            % for RVD:
            
            % high-side impedance:        
            Zhi = Zlo_ef.*(tr - 1);
                    
            % calculate loaded transfer (in/out):
            tr = (Zlo_ef + Zhi)./Zlo_ef;
            
            % continue with the corrected low-side impedance:  
            Zlo = Zlo_int;
        
        else
            % for Shunt:
            
            % recalculate its impedance from the unloaded ratio:
            Zlo = 1./tr;
            
            % subtract admittance of the connector (0.5*Zca-Yca)
            Zlo = 1./(1./Zlo - 1./(0.5*Zca_ef + 1./Yca));
                        
        end

        
        % --- 3) solve the circuit (the formulas come from symbolic solver):
        I1 = ((((4.*Ulo-4.*Uhi).*Yca.*Zih+4.*Uhi.*Yca.*Zcam-2.*Uhi.*Yca.*Zca-4.*Uhi).*Zil+(2.*Ulo.*Yca.*Zcal-4.*Ulo.*Yca.*Zcam).*Zih).*Zlo+(((2.*Ulo-2.*Uhi).*Yca.*Zcal+(2.*Ulo-2.*Uhi).*Yca.*Zca+4.*Ulo-4.*Uhi).*Zih+(2.*Uhi.*Yca.*Zcal+2.*Uhi.*Yca.*Zca+4.*Uhi).*Zcam-Uhi.*Yca.*Zca.*Zcal-Uhi.*Yca.*Zca.^2-4.*Uhi.*Zca).*Zil+((-2.*Ulo.*Yca.*Zcal-2.*Ulo.*Yca.*Zca-4.*Ulo).*Zcam+Ulo.*Yca.*Zcal.^2+(Ulo.*Yca.*Zca+4.*Ulo).*Zcal).*Zih)./(4.*Zih.*Zil.*Zlo);        
        I2 = (((2.*Ulo-2.*Uhi).*Yca.*Zih+2.*Uhi.*Yca.*Zcam-Uhi.*Yca.*Zca-2.*Uhi).*Zil+(Ulo.*Yca.*Zcal-2.*Ulo.*Yca.*Zcam).*Zih)./(2.*Zih.*Zil);

        % --- 4) calculate the input level:
        % note: I have no idea why, but the results are inverted - should be revised
        if is_rvd
            % for DIVIDER
            
            % input voltage:
            Y = -(I1.*Zhi + (I1 - I2).*Zlo);
            
        else
            % for SHUNT:
        
            % input current:
            Y = -I1;
        
        end
    
    else
        % =====================================
        % ========= SINGLE-ENDED MODE =========
        % =====================================        
        
        % --- 1) Assume the transd. was measured including the effect of the Zca-Yca
        %        and no external load. So unload it from the 0.5Zca-Yca load:
        
        % actual internal Zlo impedance:
        Zlo_int = 1./(1./(Zlo - 0.5*Zca) - Yca) - 0.5*Zca;
        
        % effective value of Zlo with 0.5Zca-Yca in parallel:
        Zlo_ef = 1./(1./Zlo_int + 1./(1./Yca + 0.5*Zca));
        
        % the complex transfer of the 0.5Zca-Yca divider (out/in):
        k_ca = 2./(Yca.*Zca + 2);
        
        % actual division ratio Zhi:Zlo_ef:
        tr = tr.*k_ca;
        
        if is_rvd
            % for RVD:
            
            % high-side impedance:        
            Zhi = Zlo_ef.*(tr - 1);
                    
            % calculate loaded transfer (in/out):
            tr = (Zlo_ef + Zhi)./Zlo_ef;
            
            % continue with the corrected low-side impedance:  
            Zlo = Zlo_int;
        
        else
            % for Shunt:
            
            % recalculate its impedance from the unloaded ratio:
            Zlo = 1./tr;
            
            % subtract admittance of the connector (0.5*Zca-Yca)
            Zlo = 1./(1./Zlo - 1./(0.5*Zca + 1./Yca));
                        
        end
           
        
        % --- 2) Calculate total impedance loading of the Zlo:
          
        % cable-to-digitizer tfer (in/out):
        k_in = (Yin.*Zcb + 2)/2;
        % (ZL+0.5*Zcb)||Ycb (temp value):
        Zx = 1./(Ycb + 1./(1./Yin + 0.5*Zcb));
        % terminal-to-cable tfer (in/out):
        k_cb = (0.5*Zcb + 0.5*Zca + Zx)./Zx;
        % (0.5*Zca+0.5*Zcb+Zx)||Yca (temp value):
        Zx = 1./(Yca + 1./(Zx + 0.5*Zca + 0.5*Zcb));
        % tranfer transducer-terminal (in/out):
        k_te = (Zx + 0.5*Zca)./Zx;
        
        % calculate loaded low-side impedance:
        Zlo_ef = 1./(1./Zlo + 1./(Zx + 0.5*Zca));
        
        if is_rvd
            % RVD:
            
            tr = (Zhi + Zlo_ef)./Zlo_ef;
            
        else
            % correct the transfer by the total load effect (in/out):
            
            tr = 1./Zlo_ef;
            
        end
          
        
        % --- 3) Apply tfer of the whole terminal-cable-digitizer chain to the trans. tfer:    
        tr = tr.*k_in.*k_cb.*k_te;
        
        % --- 4) Calculate input level:
        Y = U.*tr;
        
    end
    
    
    % convert result back to the polar form:
    Ai = abs(Y);
    phi = arg(Y);
     
    % --- evaluate uncertainty data:    
    [Ai,u_Ai] = uncdiffeval(Ai);
    [phi,u_phi] = uncdiffeval(phi);    
    % backup amplitude:
    A_tmp = Ai;
    
    if int_freq
        % --- we are operating in reduced freq spots - restore original ones ---
    
        if is_diff
            % --- differential mode:
            % note we started with selection of original spots
            
            % calculate differential of the working spots:
            dA = A.*exp(j*ph) - lo_A.*exp(j*lo_ph);            
            dph = arg(dA);
            dA  = abs(dA);
            
            % normalize calculated result to inputting working spots:
            % i.e. calculate effective transfer of the transducer relative to differential input voltage
            k_A  = Ai./dA;
            k_ph = phi - dph;
            u_k_A = u_Ai./dA;
            u_k_ph = u_phi;
            
            
            % upsample correction tfer to original freq spots:
            % note: using nearest method because there may be gaps in the tfer correction data
            %       due to the missing harmonics with larger amplitudes in the selected spots for the calculation
            k_A_r = interp1(f,k_A,f_org,'linear','extrap'); % get nearest tfer value
            k_ph_r = interp1(f,k_ph,f_org,'linear','extrap'); % get nearest tfer value
            k_A = interp1(f,k_A,f_org,int_mode,'extrap');
            k_ph = interp1(f,k_ph,f_org,int_mode,'extrap');            
            u_k_A = interp1(f,u_k_A,f_org,'next','extrap'); % take the uncertainty of the next spot 
            u_k_ph = interp1(f,u_k_ph,f_org,'next','extrap'); % take the uncertainty of the next spot
            
            % --- VERY crude @ schmutzig uncertainty estimation:
            % this tries to estimate effect of the calculation with limited harmonics count
            % by calculating difference between the fine interpolation of tfer and nearest value of tfer
            u_k_A = (u_k_A.^2 + abs(k_A - k_A_r).^2/3).^0.5;            
            u_k_ph = (u_k_ph.^2 + abs(k_ph - k_ph_r).^2/3).^0.5;
            
            % in this step we are detecting peak uncertainties per groups of freqs
            % and overwritting the individual original freq spot uncertanties
            u_A_pk = reshape(u_k_A,[grp_size F/grp_size]);
            u_A_pk = repmat(max(u_A_pk,[],1),[grp_size 1]);
            u_k_A = u_A_pk(:);            
            u_ph_pk = reshape(u_k_ph,[grp_size F/grp_size]);
            u_ph_pk = repmat(max(u_ph_pk,[],1),[grp_size 1]);
            u_k_ph = u_ph_pk(:);
                        
            
            
            % calculate differential of the original input spots:
            dA = A_org.*exp(j*ph_org) - lo_A_org.*exp(j*lo_ph_org);
            u_dA = (u_A_org.^2 + u_lo_A_org.^2).^0.5; % just estimate
            u_dph = (u_ph_org.^2 + u_lo_ph_org.^2).^0.5; % just estimate            
            dph = arg(dA);
            dA  = abs(dA);
            
            % now apply the tfer to original spots:
            Ai = k_A.*dA;
            phi = k_ph + dph;
            u_Ai = ((u_k_A.*dA).^2 + (u_dA.*dA).^2).^0.5;
            u_phi = (u_k_ph.^2 + u_dph.^2).^0.5;
            
            % note: the tfer was calculated from selection of actual input freq spot and the input voltages already
            %       included uncertainty which was propagated via the calculation.
            %       Now when the calculate tfer is applied to the original freq spots the uncertainty of the input
            %       is applied AGAIN. This is intended and it should compensate the accuracy losses due to the
            %       usage of the limited spots count.
            %       Better solution should be used but I have no idea what now...
        
        else
            % --- single-ended mode:
            % note we started with unity amplitude signal, so the result Ai-phi is transfer (in/out)
            
            % upsample tfer to original freq spots:
            Ai = interp1(f,Ai,f_org,int_mode,'extrap');
            phi = interp1(f,phi,f_org,int_mode,'extrap');
            u_Ai = interp1(f,u_Ai,f_org,int_mode,'extrap');
            u_phi = interp1(f,u_phi,f_org,int_mode,'extrap');
            
            % apply the tfer to original input data:
            Ai = Ai.*A_org;
            phi = phi + ph_org;
            % combine the correction tfer and source uncertainties:
            u_Ai = ((Ai.*u_A_org).^2 + (A_org.*u_Ai).^2).^0.5;
            u_phi = (u_phi.^2 + u_ph_org.^2).^0.5;
            
        end
        
    end
    
    % --- rms dependency of the transducer tfer ---
    % estimate input RMS value (assuming the input frequency range covers all dominant harmonics):
    rms = sum(0.5*Ai(~isnan(Ai)).^2).^0.5;
     
    
    % get final transducer transfer corrections, this time with the rms value estimation:
    % note: operating in selected freq spots, not the original spots yet! 
    tr_gain = correction_interp_table(tab.tr_gain,rms,f,'f',1,int_mode);
    tr_phi = correction_interp_table(tab.tr_phi,rms,f,'f',1,int_mode);
    tr_gain_l = correction_interp_table(tab.tr_gain,rms,f,'f',1,'linear');
    tr_phi_l = correction_interp_table(tab.tr_phi,rms,f,'f',1,'linear');
    
    % estimate possible error due to the interpolation of transducer gain tfer:
    % very crude way but gives at least some information...
    u_trg_int = abs(tr_gain.gain - tr_gain_l.gain)/3^0.5;
    u_trp_int = abs(tr_phi.phi - tr_phi_l.phi)/3^0.5;
    
    %  --- detect envelope of the tr tfer interpolation errors and use them for whole sections of tr tfer correction:
    F2 = numel(f);
    if tab.tr_gain.size_y        
        % identify centres of the tr tfer correction sections (that is where largest interpolation error is):        
        fid = interp1(f,[1:F2],0.5*(tab.tr_gain.f(1:end-1) + tab.tr_gain.f(2:end)),'nearest');
        % override uncertainty by envelope:
        u_trg_int = interp1(f(fid),u_trg_int(fid),f,'pchip','extrap');
    end
    if tab.tr_phi.size_y        
        % identify centres of the tr tfer correction sections (that is where largest interpolation error is):        
        fid = interp1(f,[1:F2],0.5*(tab.tr_phi.f(1:end-1) + tab.tr_phi.f(2:end)),'nearest');
        % override uncertainty by envelope:
        u_trp_int = interp1(f(fid),u_trp_int(fid),f,'pchip','extrap');
    end
    
    
    % calculate change agains its original assumption:
    k_A_tr = tr_gain.gain./g_org;
    k_ph_tr = tr_phi.phi - p_org;
    
    % downsample the amplitude to selected working freqs:
    A_tmp = interp1nan(f_org,Ai,f,int_mode);
    
    % get abs. uncertainties of the final transducer correction:
    u_trg = A_tmp.*(tr_gain.u_gain.^2 + u_trg_int.^2).^0.5./g_org;
    u_trp = tr_phi.u_phi;
    
    % upsample the rms dependency to original freq spots:
    k_A_tr = interp1(f,k_A_tr,f_org,int_mode,'extrap');  
    k_ph_tr = interp1(f,k_ph_tr,f_org,int_mode,'extrap');
    u_trg = interp1(f,u_trg,f_org,int_mode,'extrap');  
    u_trp = interp1(f,u_trp,f_org,int_mode,'extrap');
    
    % very nasty guess of the inherent uncertainty of the algorithm:
    % ###todo: identify the true source of errors, remove this 
    u_trp_h = (f_org/1e6)*5e-6/3^0.5;

    % finally apply the rms dependency:
    A    = Ai.*k_A_tr;
    ph   = phi + k_ph_tr;
    u_A  = (u_Ai.^2 + u_trg.^2).^0.5;
    u_ph = (u_phi.^2 + u_trp.^2 + u_trp_h.^2).^0.5;
    
    % restore original vector orientations:
    A = reshape(A,org_orient);
    ph = reshape(ph,org_orient);
    u_A = reshape(u_A,org_orient);    
    u_ph = reshape(u_ph,org_orient);
    
    % job complete and we are outahere...

end






% ---------------------------------------------------------------------------------------
% Validation - this section contains functions used to validate the bloody algorithm

 
function [] = correction_transducer_loading_test()
% this is a test function that validates the loading algorithm by
% calculating the same correction using different method - loop-currents
    
    % test Z_inv():
    z =   [1e+6 + j*1e+3; 1     + j*10e-6];
    uz = [1e+2 + j*0.1;   10e-6 + j*10e-6];
    [y,uy] = Z_inv(z,uz);
    [z2,uz2] = Z_inv(y,uy);
    if any(abs(z./z2-1) > 1e-6) || any(abs(uz./uz2-1) > 0.01)
        error('Z_inv() does not work!');
    end
    
    % test Z-phi to cplx(Z) and cplx(Z) to Z-phi covertor:
    m =  [1     ; 10];
    um = [1e-6  ; 100e-6];
    p =  [0.1   ; 1e-3];
    up = [100e-6; 1e-6];        
    [z,uz] = Zphi2Z(m,p,um,up);
    [m2,p2,um2,up2] = Z2Zphi(z,uz);
    %if any(abs(m./m2-1) > 1e-6) || any(abs(p./p2-1) > 1e-6) || any(abs(um./um2-1) > 0.02) || any(abs(up./up2-1) > 0.02)
    %    error('Z2ZPhi() or Zphi2Z() does not work!');
    %end
    
    
    % define test configurations:
    
    lab = {'full';'aproximation'};
    F_list = [500 10000];
    F_corr = 100;

    id = 0;     
    for k = 1:numel(F_list)
        
        F = F_list(k);
    
        id = id + 1; % test 1:
        cfg{id}.is_rvd = 1;
        cfg{id}.is_diff = 0;         
        cfg{id}.Rlo = 200;
        cfg{id}.D = 10;
        cfg{id}.F_corr = F_corr;
        cfg{id}.F = F;
        cfg{id}.label = ['SE, RVD test (' lab{k} ') ...'];
        
        id = id + 1; % test 2:
        cfg{id}.is_rvd = 0;
        cfg{id}.is_diff = 0;
        cfg{id}.Rlo = 20;
        cfg{id}.F_corr = F_corr;
        cfg{id}.F = F;
        cfg{id}.label = ['SE, shunt test (' lab{k} ') ...'];
        
        id = id + 1; % test 3:
        cfg{id}.is_rvd = 1;
        cfg{id}.is_diff = 1;
        cfg{id}.Rlo = 200;
        cfg{id}.D = 10;
        cfg{id}.F_corr = F_corr;
        cfg{id}.F = F;
        cfg{id}.label = ['DIFF, RVD test (' lab{k} ') ...'];
        
        id = id + 1; % test 4:
        cfg{id}.is_rvd = 0;
        cfg{id}.is_diff = 1;
        cfg{id}.Rlo = 20;
        cfg{id}.F_corr = F_corr;
        cfg{id}.F = F;
        cfg{id}.label = ['DIFF, shunt test (' lab{k} ') ...'];
    end
    
    id = id + 1;
    cfg{id}.is_rvd = 0;
    cfg{id}.is_diff = 1;
    cfg{id}.Rlo = 20;
    cfg{id}.F_corr = F_corr;
    cfg{id}.F = 20000;
    cfg{id}.A_max = 1;
    cfg{id}.A_min = 10e-6;    
    cfg{id}.A_noise = 1e-6;
    cfg{id}.A_count = 500;        
    cfg{id}.label = 'DIFF, shunt test, many random freq spots ...';
    cfg{id}.plot = 1;
    
    
    
    
        
    for c = 1:numel(cfg)
    
        % setup for current test:
        s = cfg{c};
        
        disp(s.label);
        
        % interpolation mode of the freq characteristics:
        % note: must be identical to the one used by the main function
        int_mode = 'pchip';
    
        % frequency range of the simulation:
        Fc = s.F_corr; % max correction spots
        F = s.F; % data points (signal components to correct)
        f = [];
        f(:,1) = logspace(log10(10),log10(1e6),F);
        fc = [];
        Fc = min(F,Fc);
        fc(:,1) = logspace(log10(10),log10(1e6),Fc);
        w = f*2*pi;
        
        % randomized spectrum?
        a_is_rand = isfield(s,'A_count');
        
        % generate some spectrum:
        if ~a_is_rand
            % fixed amps:
            A = ones(size(f));
            ph = zeros(size(f));
        else
            % randomized amps:
            aid = randperm(F,s.A_count).';
            
            % generate default noise:
            A = rand(F,1)*s.A_noise;
            
            % insert randomized amplitudes (in log space) to randomized frequencies:
            A(aid) = 10.^(log10(s.A_min) + (log10(s.A_max) - log10(s.A_min))*rand(s.A_count,1));
            
            % rand phase angles:
            ph = (1 - 2*rand(F,1))*pi*0.9;
                        
        end
        u_A = 0*A;
        u_ph = 0*ph;
        
        % estimate rms value:
        rms_v = sum(0.5*A.^2).^0.5;
            
        % rms range of the transd. transfers:
        rms = [];
        rms(1,:) = [0 1.1*rms_v 2*rms_v];
        R = numel(rms);
        
        % define low side impedance Cp+Rp:
        Rlo = s.Rlo;
        Clo = 50e-12;
        Zlo = 1./(1/Rlo + j*w*Clo);
        
        % nominal DC ratio of the transducer (in/out):
        if s.is_rvd
            D = s.D;
        else
            D = 0;
        end
        
        if s.is_rvd
            % RVD high side parallel capacitance:
            Chi = Clo/(D-1);
            
            % RVD calculate high side impedance:
            Zhi = 1./(1/((D - 1)*Rlo) + j*w*Chi);
        else
            % no high-side resistor for shunt mode:
            Zhi = repmat(1e-15,[F 1]);
        end
        
        % define low return path series impedance (diff mode only):
        Rr = 1;
        Lr = 5e-6;
        Zx = Rr + j*w*Lr;
        
        % define terminals impedances:
        Ls_a = 1000e-9;
        Rs_a = 50e-3;
        Cp_a = 100e-12;
        D_a = 0.01;
        Zca = Rs_a + j*w*Ls_a;
        Yca = w*Cp_a*(j + D_a);
        % low-side:
        Zcal = 1.2*Zca;
        % mutual:
        Ma = 300e-9;
        Zcam = j*w*Ma;
                
        % define cable's impedance:
        len_b = 0.5;
        Ls_b = 250e-9;
        Rs_b = 50e-3;
        Cp_b = 105e-12;
        D_b = 0.02;
        Zcb = (Rs_b + j*w*Ls_b)*len_b;
        Ycb = w*Cp_b*(j + D_b)*len_b;
        
        % define digitizer input impedance Cp-Rp:
        Cp_i = 50e-12;
        Rp_i = 1e6;
        Yin = 1./Rp_i + j*w*Cp_i;
        Yinl = Yin;
        Zin = 1./Yin;
        Zinl = 1./Yinl;
        
        if s.is_diff
            % calculate effective value of the Zlo when loaded by 0.5*Zca-0.5*Zcal-Yca:
            Zca_ef = Zca + Zcal;            
            Zlo_ef = 1./(1./Zlo + 1./(1./Yca + 0.5*Zca_ef));
            
            % transfer of the terminals 0.5*Zca-0.5*Zcal-Yca (in/out):
            k_te = (Yca.*Zca_ef + 2)./2;
            
            % calculate measurable low side impedance (measured via the output terminals):
            % note: this is what user will measure when doing calibration
            Zlo_meas = 1./(1./(Zlo + 0.5*Zca_ef) + Yca) + 0.5*Zca_ef;
        else
            % calculate effective value of the Zlo when loaded by 0.5*Zca-Yca:
            Zlo_ef = 1./(1./Zlo + 1./(1./Yca + 0.5*Zca));
            
            % transfer of the terminals 0.5*Zca-Yca (in/out):
            k_te = (Yca.*Zca + 2)./2;
            
            % calculate measurable low side impedance (measured via the output terminals):
            % note: this is what user will measure when doing calibration
            Zlo_meas = 1./(1./(Zlo + 0.5*Zca) + Yca) + 0.5*Zca;
        end
                
        
        % calculate effective transfer from input to transducer terminals (in/out):
        % note: this is what user will measure when doing calibration
        if s.is_rvd
            k_ef = (Zlo_ef + Zhi)./Zlo_ef.*k_te;
        else
            k_ef = 1./Zlo_ef.*k_te;
        end
          
        % type of the transducer (control string for the corr. function):
        tran = {'shunt','rvd'};
        tran = tran{1 + s.is_rvd};                
        
        % reinterpolate 'measured' transfer to correction freq spots:
        g = abs(k_ef);    
        p = arg(k_ef);            
        [gc,pc,u_gc,u_pc] = decim_corr_data(g,p,f,fc,int_mode);
        
        % simulate transd. transfer and uncertainty (gain):
        gc = repmat(gc,[1 R]);
        u_gc = repmat(u_gc,[1 R]);
        % simulate transd. transfer and uncertainty (phase):
        pc = repmat(pc,[1 R]);
        u_pc = repmat(u_pc,[1 R]);             
        
        % remove some elements from the transd. tfer to emulate real correction data:
        gc(end,end) = NaN;
        u_gc(end,end) = NaN;
        
        % build transd. tfer tables:        
        tab.tr_gain = correction_load_table({fc,rms,gc,u_gc},'rms',{'f','gain','u_gain'});
        tab.tr_phi = correction_load_table({fc,rms,pc,u_pc},'rms',{'f','phi','u_phi'});
        
        U = ones(Fc,1);
        
        % build RVD's low-side impedance table:
        [gc,pc,u_gc,u_pc] = decim_corr_data(g,p,f,fc,int_mode);        
        t_Rp = 1./real(1./Zlo_meas);
        t_Cp = imag(1./Zlo_meas)./w;
        t_Rp = interp1nan(f,t_Rp,fc,int_mode);
        t_Cp = interp1nan(f,t_Cp,fc,int_mode);
        tab.tr_Zlo = correction_load_table({fc,t_Rp,t_Cp,0*t_Rp,0*t_Cp},'',{'f','Rp','Cp','u_Rp','u_Cp'});
        
        
        % build terminal tables:    
        t_Rs = real(Zca);
        t_Ls = imag(Zca)./w;
        t_Rs = interp1nan(f,t_Rs,fc,'linear');
        t_Ls = interp1nan(f,t_Ls,fc,'linear');
        tab.tr_Zca = correction_load_table({fc,t_Rs,t_Ls,0*t_Rs,0*t_Ls},'',{'f','Rs','Ls','u_Rs','u_Ls'});
        t_Cp = imag(Yca)./w;
        t_D = real(Yca)./imag(Yca);
        t_Cp = interp1nan(f,t_Cp,fc,'linear');
        t_D = interp1nan(f,t_D,fc,'linear');
        tab.tr_Yca = correction_load_table({fc,t_Cp,t_D,0*t_Cp,0*t_D},'',{'f','Cp','D','u_Cp','u_D'});
        t_Rs = real(Zcal);
        t_Ls = imag(Zcal)./w;
        t_Rs = interp1nan(f,t_Rs,fc,'linear');
        t_Ls = interp1nan(f,t_Ls,fc,'linear');
        tab.tr_Zcal = correction_load_table({fc,t_Rs,t_Ls,0*t_Rs,0*t_Ls},'',{'f','Rs','Ls','u_Rs','u_Ls'}); % low-side
        t_M = imag(Zcam)./w;
        t_M = interp1nan(f,t_M,fc,'linear');
        tab.tr_Zcam = correction_load_table({fc,t_M,0*t_M},'',{'f','M','u_M'}); % mutual
        
        % build cable tables:
        t_Rs = real(Zcb);
        t_Ls = imag(Zcb)./w;
        t_Rs = interp1nan(f,t_Rs,fc,'linear');
        t_Ls = interp1nan(f,t_Ls,fc,'linear');
        tab.Zcb = correction_load_table({fc,t_Rs,t_Ls,0*t_Rs,0*t_Ls},'',{'f','Rs','Ls','u_Rs','u_Ls'});
        t_Cp = imag(Ycb)./w;
        t_D = real(Ycb)./imag(Ycb);
        t_Cp = interp1nan(f,t_Cp,fc,'linear');
        t_D = interp1nan(f,t_D,fc,'linear');
        tab.Ycb = correction_load_table({fc,t_Cp,t_D,0*t_Cp,0*t_Cp},'',{'f','Cp','D','u_Cp','u_D'});
    
        % digitizer's input impedance:
        t_Cp = imag(Yin)./w;
        t_Gp = real(Yin);
        t_Cp = interp1nan(f,t_Cp,fc,'linear');
        t_Gp = interp1nan(f,t_Gp,fc,'linear');
        tab.adc_Yin = correction_load_table({fc,t_Cp,t_Gp,0*t_Cp,0*t_Gp},'',{'f','Cp','Gp','u_Cp','u_Gp'});
        t_Cp = imag(Yinl)./w;
        t_Gp = real(Yinl);
        t_Cp = interp1nan(f,t_Cp,fc,'linear');
        t_Gp = interp1nan(f,t_Gp,fc,'linear');
        tab.lo_adc_Yin = correction_load_table({fc,t_Cp,t_Gp,0*t_Cp,0*t_Gp},'',{'f','Cp','Gp','u_Cp','u_Gp'}); % low-side
                
        
        % --- now the fun part - exact forward solution ---
        
        % move frequency dependence to the third dim:
        Zhi  = reshape(Zhi,[1,1,F]);
        Zlo  = reshape(Zlo,[1,1,F]);
        Zin  = reshape(Zin,[1,1,F]);
        Zinl = reshape(Zinl,[1,1,F]);
        Zca  = reshape(Zca,[1,1,F]);
        Yca  = reshape(Yca,[1,1,F]);
        Zcal = reshape(Zcal,[1,1,F]);
        Zcam = reshape(Zcam,[1,1,F]);
        Zcb  = reshape(Zcb,[1,1,F]);
        Ycb  = reshape(Ycb,[1,1,F]);
        Zx   = reshape(Zx,[1,1,F]);
        Z    = zeros(size(Zhi));
        
        if s.is_diff
            % --- diff mode:
            
            % simplify the cable->digitizer joints (step 1):
            Zih = 1./(1./(Zin + 0.5*Zcb) + Ycb);
            Zil = 1./(1./(Zinl + 0.5*Zcb) + Ycb);
            tfh = Zih./(Zih + 0.5*Zcb).*Zin./(Zin + 0.5*Zcb);
            tfl = Zil./(Zil + 0.5*Zcb).*Zinl./(Zinl + 0.5*Zcb);
            Zih = Zih + 0.5*Zcb;
            Zil = Zil + 0.5*Zcb;
            
            % loop-currents matrix:
            L = [ Zhi+Zlo+Zx      -Zlo                              Z                                       -Zx              ;
                 -Zlo              Zlo+1./Yca+0.5*Zca+0.5*Zcal     -1./Yca                                  -0.5*Zcal        ;
                  Z               -1./Yca                           1./Yca+0.5*Zca+0.5*Zcal+Zih+Zil-2*Zcam  -Zcal/2-Zil+Zcam ;
                 -Zx              -0.5*Zcal                        -0.5*Zcal-Zil+Zcam                        Zx+Zcal+Zil    ];
                 
            % define loop voltages:
            U = [1;0;0;0];
            
            % solve for each frequency: 
            I = [];
            for k = 1:F       
                I(:,k) = L(:,:,k)\U;
            end
            
            % extract currents:
            I1 = I(1,:)(:);
            I2 = I(2,:)(:);
            I3 = I(3,:)(:);
            I4 = I(4,:)(:);
                        
            if s.is_rvd
                % -- RVD mode:
                
                % input voltage:
                Uin = A.*exp(j*ph);
                
                % correction to desired RVD input voltage:
                k = Uin./(1 - (I1 - I4).*Zx(:));
                
            else
                % -- shunt mode:
                
                % input current:
                Iin = A.*exp(j*ph);
                
                % correction to the desired input current:
                k = Iin./I1;
                
            end
            
            % high-side voltage:
            Uih = I3.*Zih(:).*k.*tfh(:);
            % low-side voltage:
            Uil = (I4 - I3).*Zil(:).*k.*tfl(:);

            % convert voltages to polar:
            Aih = abs(Uih);
            phih = arg(Uih);
            Ail = abs(Uil);
            phil = arg(Uil);
            
            % --- apply the loading correction to obtain original signal:
            tic();
            [Ax,phx,u_Ax,u_phx] = correction_transducer_loading(tab,tran,f,[], Aih,phih,0*Aih,0*phih, Ail,phil,0*Ail,0*phil);
        
        else
            % --- single-ended mode:
                
            % loop-currents matrix:
            L = [ Zhi+Zlo  -Zlo                  Z                               Z;
                 -Zlo       Zlo+0.5*Zca+1./Yca  -1./Yca                          Z;
                  Z        -1./Yca               1./Yca+0.5*Zca+0.5*Zcb+1./Ycb  -1./Ycb;
                  Z         Z                   -1./Ycb                          1./Ycb+0.5*Zcb+Zin];
        
            % define loop voltages:
            U = [1;0;0;0];
            
            % solve for each frequency: 
            I = [];
            for k = 1:F       
                I(:,k) = L(:,:,k)\U;
            end
            
            % forward transfer (out/in):
            if s.is_rvd
                tfer = I(4,:)(:).*Zin(:);
            else
                tfer = I(4,:)(:).*Zin(:)./I(1,:)(:);
            end
            
            % extract magnitude and phase:
            A_in = A.*abs(tfer);
            ph_in = ph + arg(tfer);
            
            % --- apply the loading correction to obtain original signal:
            tic();
            [Ax,phx,u_Ax,u_phx] = correction_transducer_loading(tab,tran,f,[], A_in,ph_in,0*A_in,0*ph_in);
            
        end
        t_corr = toc();
        
        if isfield(s,'plot') && s.plot
            figure       
            semilogx(f,Ax - A)
            hold on;
            semilogx(f,+2*u_Ax,'r')
            semilogx(f,-2*u_Ax,'r')
            hold off;
            title([s.label ' - gain']);
            
            figure
            semilogx(f,phx - ph)
            hold on;
            semilogx(f,+2*u_phx,'r')
            semilogx(f,-2*u_phx,'r')
            hold off;
            title([s.label ' - phase']);
        end
        
        % define maximum deviations of the results from generated values (not including result uncertainty!):
        u_Ax_lim = 1e-6*A;
        u_phx_lim = 1e-6;
        
        % check correctness of the calculation    
        assert(all(abs(Ax - A) < max(u_Ax_lim,u_Ax*2)),[s.label ' gain not matching!']);
        assert(all(abs(phx - ph) < max(u_phx_lim,u_phx*2)),[s.label ' phase not matching!']);
        
        
        
        disp(sprintf(' ... ok in %.2f s.',t_corr));
    
    end
    
    %plot(f,Ax - A)
    
    
%     F = 100000; % data points (signal components to correct)
%     f = [];
%     f(:,1) = logspace(log10(10),log10(1e6),F);
%     
%     % generate some spectrum:
%     Aih = ones(size(f));
%     phih = zeros(size(f));    
%     Ail = 0.1*ones(size(f));
%     phil = zeros(size(f));
%     
%     tic
%     [Ax,phx] = correction_transducer_loading(tab,tran,f, Aih,phih,0*Aih,0*phih, Ail,phil,0*Ail,0*phil);
%     toc
    


end



function [a2,b2,u_a2,u_b2] = decim_corr_data(a1,b1,f1,f2,i_mode)
% decimator of the correction dependencies 'a1' and 'a2' from freqs 'f1' to freqs 'f2'
% it will interpolate the 'a1', 'b1' and estimates the standard uncertainty 
% introduced by the interpolation (very crude estimation)

    if nargin < 5
        i_mode = 'linear';
    end
    
    % freq counts:
    F1 = numel(f1);
    F2 = numel(f2);
    
    % downsample correction data to f2:
    a2 = interp1nan(f1,a1,f2,i_mode);
    b2 = interp1nan(f1,b1,f2,i_mode);
    
    % upsample back to original f1:
    a3 = interp1nan(f2,a2,f1,i_mode);
    b3 = interp1nan(f2,b2,f1,i_mode);
    
    % calculate error against the original data:
    da = abs(a3 - a1);
    db = abs(b3 - b1);
    
    % identify centres of the sections F (that is where largest interpolation error is):
    fid = interp1(f1,[1:F1],0.5*(f2(1:end-1) + f2(2:end)),'nearest');
    
    % estimate standard uncertainty for the interpolation section
    u_a2 = [da(fid);da(fid(end))]/3^0.5;
    u_b2 = [db(fid);db(fid(end))]/3^0.5;
    
    %figure
    %semilogx(f1,db)
    %hold on;
    %semilogx(f2,u_b2*3^0.5,'r')
    %hold off;
            
end






% ---------------------------------------------------------------------------------------
% Other stuff

function [mid,S] = find_mjr_freqs(Ahi,Alo,N)
% Splits list of diff amplitudes dA = abs(Ahi - Alo) to max N groups,
% searches for maximum amplitude per each group, return indices of the
% maxima in the original spots Ahi,Alo
% Note: this should be signifficantly improve by some heuristic mechanisms
%       to skip the groups with too low amplitudes and replace them with 
%       average of surrounding ones, but no time for that yet...

    % differential input voltage:
    dA = abs(Ahi - Alo);
    
    % total input freq spots:
    AN = numel(Ahi);
    
    % freqs group size:    
    S = ceil(AN/N);
    
    % total frequency groups:
    G = ceil(AN/S);
    
    % padding the input spots to G multiple:
    dA = [dA;zeros([AN - G*S 1])];
    
    % reshape (spots, groups):
    gA = reshape(dA,[S G]);
        
    % identify maximum amplitudes per group:
    [v,mid] = max(gA,[],1);
    mid = mid(:);     
    
    % convert maximum indexes to original spot positions:
    mid = mid + S*[0:G-1].';    
    mid = min(mid,AN);

end


% --- uncertainty tools ---
% This function creates matrix of a 'q' to enable simple numeric propagation of uncertainty by
% differences method. It will create a matrix of vertical vector 'q' and 'u_q':
%   column 1     column 'id'*2   column 'id'*2+1  others:
%   q            q + real(u_q)   q + imag(u_q)    q
%
% 'tot' is total number of input quantities involved in the uncertainty evaluation.
% So for a model: d = (a + b)/c, the calling order is:
% am = uncdiff(a,u_a,1,3); 
% bm = uncdiff(b,u_b,2,3);
% cm = uncdiff(c,u_c,3,3);
% dm = (am + bm)./cm;
% [d,u_d] = uncdiffeval(dm); 
function [qm] = uncdiff(q,uq,id,tot)

    % store mean value:
    qm = repmat(q,[1 tot*2+1]);  
    % store real difference:
    qm(:,id*2+0) = q + real(uq);   
    % store imag difference:
    qm(:,id*2+1) = q + imag(uq);
    
end
% uncertainty evaluation function for uncdiff():
function [q,u_q] = uncdiffeval(qm)
    
    % total contributing quantities count:
    tot = (size(qm,2) - 1)/2;
    
    % mean value:
    q = qm(:,1);
    
    % differences (uncertainty contributions):
    df = qm(:,2:end) - q;
    
    % combined uncertainty:
    u_q = sum(real(df).^2,2).^0.5 + j*sum(imag(df).^2,2).^0.5;    
    
end

% ---------------------------------------------------------------------------------------
% Impedance conversion routines

% conversion of complex Z to Y and vice versa
function [Y,uY] = Z_inv(Z,uZ)

  Rs = real(Z);
  Xs = imag(Z);
  uRs = real(uZ);
  uXs = imag(uZ);
  
  uGp = (4*Rs.^2.*Xs.^2.*uXs.^2+(Xs.^4-2*Rs.^2.*Xs.^2+Rs.^4).*uRs.^2).^0.5./(Xs.^8+4*Rs.^2.*Xs.^6+6*Rs.^4.*Xs.^4+4*Rs.^6.*Xs.^2+Rs.^8).^0.5;
  %uGp =  (4*Rs.^2.*Xs.^2.*uXs.^2+(Xs.^4-2*Rs.^2.*Xs.^2+Rs.^4).*uRs.^2).^0.5./(Xs.^8+4*Rs.^2.*Xs.^6+6*Rs.^4.*Xs.^4+4*Rs.^6.*Xs.^2+Rs.^8).^0.5;
  %uGp = ((4*Rs.^2.*Xs.^2.*uXs.^2)./(Xs.^2+Rs.^2).^4+(1./(Xs.^2+Rs.^2)-(2*Rs.^2)./(Xs.^2+Rs.^2).^2).^2.*uRs.^2).^0.5;  
  uBp = ((Xs.^4-2*Rs.^2.*Xs.^2+Rs.^4).*uXs.^2+4*Rs.^2.*Xs.^2.*uRs.^2).^0.5./(Xs.^8+4*Rs.^2.*Xs.^6+6*Rs.^4.*Xs.^4+4*Rs.^6.*Xs.^2+Rs.^8).^0.5;
  
  Y = complex(1./Z);
  uY = complex(uGp,uBp); 
    
end


% conversion of Z-phi [Ohm-rad] scheme to complex Y scheme with uncertainty
% note: it has been crippled by the bsxfun() for Matlab < 2016b - do not remove!
function [Z,u_Z] = Zphi2Z(Z,phi,u_Z,u_phi)
    
    % re: sqrt(Z^2*sin(phi)^2*u_phi^2+cos(phi)^2*u_Z^2):
    % im: sqrt(g^2*cos(p)^2*u_p^2+sin(p)^2*u_g^2):
    %u_Z = sqrt(Z.^2.*sin(phi).^2.*u_phi.^2 + cos(phi).^2.*u_Z.^2) + j*sqrt(Z.^2.*cos(phi).^2.*u_phi.^2 + sin(phi).^2.*u_Z.^2);
    u_Z = (Z.^2.*sin(phi).^2.*u_phi.^2 + cos(phi).^2.*u_Z.^2).^0.5 + j*(Z.^2.*cos(phi).^2.*u_phi.^2 + sin(phi).^2.*u_Z.^2).^0.5;
       
    % Z = Z*e(j*phi) [Ohm + jOhm]:
    Z = Z.*exp(j*phi); 

end


% conversion of complex Z to Z-phi [Ohm-rad] scheme
% note: it has been crippled by the bsxfun() for Matlab < 2016b - do not remove!
function [Z,phi,u_Z,u_phi] = Z2Zphi(Z,u_Z)
 
    % extract real and imag parts:
    re = real(Z);
    im = imag(Z);
    u_re = real(u_Z);
    u_im = imag(u_Z);
        
    % sqrt(re^2*u_re^2+im^2*u_im^2)/sqrt(re^2+im^2)):
    %u_Z = sqrt(re.^2.*u_re.^2 + im.^2.*u_im.^2)./sqrt(re.^2 + im.^2);
    u_Z = (re.^2.*u_re.^2 + im.^2.*u_im.^2).^0.5./(re.^2 + im.^2).^0.5;
    
    % sqrt(im^2*u_re^2+re^2*u_im^2)/(re^2+im^2):
    %u_phi = sqrt(im.^2.*u_re.^2 + re.^2.*u_im.^2)./(re.^2 + im.^2);
    u_phi = (im.^2.*u_re.^2 + re.^2.*u_im.^2).^0.5./(re.^4 + 2*im.^2.*re.^2 + im.^4).^0.5;
    
    % convert to polar:
    phi = arg(Z);
    Z = abs(Z); 

end


% conversion of Cp-D scheme to complex Y scheme with uncertainty
% note: it has been crippled by the bsxfun() for Matlab < 2016b - do not remove!
function [Y,u_Y] = CpD2Y(f,Cp,D,u_Cp,u_D)
 
    % nagular freq [rad/s]:
    w = 2*pi*f;
    
    % Y = w.*Cp.*(j + D) [S + jS]:
    Y = bsxfun(@times,w,Cp).*(j + D);
    
    % re: sqrt(Cp^2*u_D^2+D^2*u_Cp^2)*abs(w):
    % im: abs(u_Cp)*abs(w):
    u_Y = bsxfun(@times,sqrt(Cp.^2.*u_D.^2 + D.^2.*u_Cp.^2),w) + j*bsxfun(@times,u_Cp,w);

end


% conversion of Cp-Gp scheme to complex Y scheme with uncertainty
% note: it has been crippled by the bsxfun() for Matlab < 2016b - do not remove!
function [Y,u_Y] = CpGp2Y(f,Cp,Gp,u_Cp,u_Gp)
 
    % angular freq [rad/s]:
    w = 2*pi*f;
    
    % admittance [S + jS]:
    Y = Gp + j*bsxfun(@times,w,Cp);
    
    % uncerainty [S + jS]:
    u_Y = u_Gp + j*bsxfun(@times,w,u_Cp);

end


% conversion of Cp-Rp scheme to complex Z scheme with uncertainty
% note: it has been crippled by the bsxfun() for Matlab < 2016b - do not remove!
function [Z,u_Z] = CpRp2Z(f,Cp,Rp,u_Cp,u_Rp)
 
    % nagular freq [rad/s]:
    w = 2*pi*f;
    
    % complex Z [Ohm + jOhm]:
    Z = 1./(j*bsxfun(@times,Cp,w) + 1./Rp);
        
    % uncertainty [Ohm + jOhm]:
    re = sqrt(bsxfun(@times,Cp.^4.*Rp.^4.*u_Rp.^2 + 4*Cp.^2.*Rp.^6.*u_Cp.^2,w.^4) - 2*Cp.^2.*Rp.^2.*u_Rp.^2.*w.^2 + u_Rp.^2)./(bsxfun(@times,Cp.^4.*Rp.^4,w.^4) + bsxfun(@times,2*Cp.^2.*Rp.^2,w.^2) + 1);
    im = (bsxfun(@times,Cp.^2.*Rp.^4.*u_Cp,w.^3) - bsxfun(@times,Rp.^2.*u_Cp,w))./(bsxfun(@times,Cp.^4.*Rp.^4,w.^4) + bsxfun(@times,2*Cp.^2.*Rp.^2,w.^2) + 1);
    u_Z = re + j*im;    

end


% conversion of Ls-Rs scheme to complex Z scheme with uncertainty
% note: it has been crippled by the bsxfun() for Matlab < 2016b - do not remove!
function [Z,u_Z] = LsRs2Z(f,Ls,Rs,u_Ls,u_Rs)
 
    % nagular freq [rad/s]:
    w = 2*pi*f;
    
    % Z = j*w*Ls + Rs [Ohm + jOhm]:
    Z = j*bsxfun(@times,w,Ls) + Rs;
    
    % re: abs(u_Rs)
    % im: abs(u_Ls)*abs(w)
    u_Z = u_Rs + j*bsxfun(@times,u_Ls,w);

end







% ======================================================================================
% LOCAL COPY OF SOME TWM FUNCTIONS TO ENSURE THIS FUNCTION IS STANDALONE
% ======================================================================================

function [tbl] = correction_load_table(file,second_ax_name,quant_names)
% TWM: Loader of the correction CSV file.
%
% This will load single CSV file of 1D or 2D dependence into structure.
%
% [tbl] = correction_load_table(file, second_ax_name, quant_names)
% [tbl] = correction_load_table(file, second_ax_name, quant_names, i_mode)
%
% Parameters:
%  file - full file path to the CSV file
%       - may be replaced by cell array {quant. 1, quant. 2, ...},
%         that will fake the CSV table with the values defined in the cells
%         both axis of dependence will be empty. 
%  second_ax_name - if secondary CSV is 2D dependence, this is name of
%                   of the variable to which the secondary axis values
%                   will be placed.
%  quant_names - names of the quantities in the CSV file
%              - first one is always independent quantity (primary axis),
%                following strings are names of the dependent quantities
%  i_mode      - interpolation mode (default: 'linear')
%
% Returns:
%  tbl.name - CSV file comment
%  tbl.'quant_names{1}' - primary axis values
%  tbl.'second_ax_name' - secondary axis values (optional)
%  tbl.'quant_names{2}' - quantity 1 data
%  ...
%  tbl.'quant_names{N+1}' - quantity N data
%  tbl.quant_names - names of the data quantities
%  tbl.axis_x - name of the secondary axis quantity
%  tbl.axis_y - name of the primary axis quantity
%  tbl.has_x - secondary axis exist (even if it is empty)
%  tbl.has_y - primary axis exist (even if it is empty)
%  tbl.size_x - secondary axis size (0 when quantities independent on X)
%  tbl.size_y - primary axis size (0 when quantities independent on Y)
%
%
% Notes:
% Missing quantity values in the middle of the data will be interpolated
% per rows (linear mode by default).
% Missing (empty) cells on the starting and ending rows will be replaced
% by NaN.
%
% CSV format example (2D dependence):
% My CSV title ;         ;         ;            ;
%              ; Rs(Ohm) ; Rs(Ohm) ; u(Rs)(Ohm) ; u(Rs)(Ohm)
% f(Hz)\U(V)   ; 0.1     ; 1.0     ; 0.1        ; 1.0
% 0            ; 6.001   ; 6.002   ; 0.1        ; 0.1
% 1000         ; 6.010   ; 6.012   ; 0.2        ; 0.2
% 10000        ; 6.100   ; 6.102   ; 0.5        ; 0.5
%
% CSV format example (2D dependence, but independent on U axis):
% My CSV title ;         ;           
%              ; Rs(Ohm) ; u(Rs)(Ohm)
% f(Hz)\U(V)   ;         ;        
% 0            ; 6.001   ; 0.1       
% 1000         ; 6.010   ; 0.2       
% 10000        ; 6.100   ; 0.5       
%
% CSV format example (2D dependence, but independent on f axis):
% My CSV title ;         ;         ;            ;
%              ; Rs(Ohm) ; Rs(Ohm) ; u(Rs)(Ohm) ; u(Rs)(Ohm)
% f(Hz)\U(V)   ; 0.1     ; 1.0     ; 0.1        ; 1.0
%              ; 6.001   ; 6.002   ; 0.1        ; 0.1
%
% CSV format example (2D dependence, but independent on any axis):
% My CSV title ;         ;           
%              ; Rs(Ohm) ; u(Rs)(Ohm)
% f(Hz)\U(V)   ;         ;        
%              ; 6.001   ; 0.1       
%
% CSV format example (1D dependence):
% My CSV title ;         ;         ;            ;
% f(Hz)        ; Rs(Ohm) ; Rs(Ohm) ; u(Rs)(Ohm) ; u(Rs)(Ohm)
% 0            ; 6.001   ; 6.002   ; 0.1        ; 0.1
% 1000         ; 6.010   ; 6.012   ; 0.2        ; 0.2
% 10000        ; 6.100   ; 6.102   ; 0.5        ; 0.5
%
%
% This is part of the TWM - TracePQM WattMeter (https://github.com/smaslan/TWM).
% (c) 2018, Stanislav Maslan, smaslan@cmi.cz
% The script is distributed under MIT license, https://opensource.org/licenses/MIT.                
% 
  
  % by default assume no secondary axis
  if isempty(second_ax_name)
    second_ax_name = '';  
  end
  
  % identify interpolation mode:
  if ~exist('i_mode','var')
    i_mode = 'linear';
  end
  
  if iscell(file)
    % default table
    
    % which axes are there?
    has_primary = ~isempty(quant_names{1});
    has_second = ~isempty(second_ax_name);

    % data quantities count
    quant_N = numel(quant_names) - 1;
    
    if numel(file) ~= quant_N + has_primary + has_second
      error('Correction table loader: Number of data quantities does not match number of fake values to assign! Note the primary axis quantity is used even for faking table, so valid example is: quant_names = {''f'',''Rs'',''Xs''}, file = {[], 0, 0}.');
    end
    
    % fake table content
    tbl.name = 'fake table';
    
    fpos = 1;
    
    % store primary axis
    if has_primary
      tbl = setfield(tbl,quant_names{1},file{fpos});
      fpos = fpos + 1;
    end
    % store secondary axis
    if has_second
      tbl = setfield(tbl,second_ax_name,file{fpos});
      fpos = fpos + 1;
    end
    % store quantities 
    for k = 1:quant_N
      tbl = setfield(tbl,quant_names{k+1},file{fpos});
      fpos = fpos + 1;
    end       
    
  else
  
    % try to load the table
    csv = csv2cell(file,';');
    [M,N] = size(csv);
    
    % get rid of empty rows/columns
    for m = M:-1:1
      if ~all(cellfun(@isempty,csv(m,:)))
        M = m;
        break;
      end
    end  
    for n = N:-1:1
      if ~all(cellfun(@isempty,csv(:,n)))
        N = n;
        break;
      end
    end
    
    % check consistency of the table data and desired quantities count
    Q = numel(quant_names);
    if Q < 2
      error('Correction table loader: not enough dependence quantities!');
    end  
    if rem(N - 1,Q - 1)
      error('Correction table loader: quantities count does not match size of the loaded table!');
    end
    
    % number of columns per quantity
    A = round((N - 1)/(Q - 1));  
    if isempty(second_ax_name) && A > 1
      error('Correction table loader: no secondary axis desired but correction data contain more than 1 column per quantity!');
    end
        
    % read name of the table
    tbl.name = csv{1,1};
    
    % initial row of correction data
    d_row = 3;
    if ~isempty(second_ax_name)
      d_row = d_row + 1;
    end
  
    
    % load primary axis values
    numz = cellfun(@isnumeric,csv(d_row:end,1)) & ~cellfun(@isempty,csv(d_row:end,1));
    if any(numz) && ~all(numz)
      error('Correction table loader: primary axis contains invalid cells!');
    end
    if numel(numz) == 1 && any(numz)
      error('Correction table loader: primary axis contains invalid cells! There is just one row so there should not be primary axis value, just empty cell!');
    elseif any(numz)
      tbl = setfield(tbl,quant_names{1},cell2mat(csv(d_row:end,1)));
    else
      tbl = setfield(tbl,quant_names{1},[]);    
    end
    prim = getfield(tbl,quant_names{1});
    
    % load secondary axis values
    if ~isempty(second_ax_name)
      numz = cellfun(@isnumeric,csv(d_row-1,2:1+A)) & ~cellfun(@isempty,csv(d_row-1,2:1+A));
      if any(numz) && ~all(numz) 
        error('Correction table loader: secondary axis contains invalid cells!');
      end
      if ~any(numz) && A > 1
        error('Correction table loader: secondary axis contains invalid cells! There are multiple columns per quantity but not all have assigned secondary axis values.');
      elseif any(numz) && A == 1
        error('Correction table loader: secondary axis contains invalid cells! There is just on secondary axis item but it has nonzero value. It should be empty.');
      elseif ~any(numz) || A == 1
        tbl = setfield(tbl,second_ax_name,[]);
      else  
        tbl = setfield(tbl,second_ax_name,cell2mat(csv(d_row-1,2:1+A)));
      end
    end
    
    % --- for each quantity in the table
    for q = 1:Q-1
      
      % load csv portion with correction data
      vv = csv(d_row:end,2+(q-1)*A:1+q*A);
      R = size(vv,1);
      
      % detect invalids
      nanz = cellfun(@isempty,vv) | ~cellfun(@isnumeric,vv);
      
      for a = 1:A
        
        % get id of valid rows
        vid = find(~nanz(:,a));
        if ~numel(vid)
          error('Correction table loader: no valid number in whole column???');  
        end
        
        % build primary axis
        if isempty(prim)
          p = [];
        else
          p = prim(vid);
        end
        % build column
        d = [vv{vid,a}].';
  
        if numel(p) > 1
          % interpolate data to fill in gaps and replace ends by NaNs     
          vv(1:end,a) = num2cell(interp1(p,d,prim,i_mode));
        else
          % just one row, cannot interpolate
          tmp = vv(1:end,a);
          vv(1:end,a) = NaN;
          vv(vid,a) = tmp(vid);
                 
        end
        
      end
      
      
      % convert and store quantity to loaded table
      tbl = setfield(tbl,quant_names{1+q},cell2mat(vv));
          
    end
    
  end
  
  % store axes names
  tbl.axis_x = second_ax_name;
  tbl.has_x = ~isempty(tbl.axis_x);  
  if tbl.has_x
    tbl.size_x = numel(getfield(tbl,second_ax_name));
  else
    tbl.size_x = 0; 
  end  
  tbl.axis_y = quant_names{1};
  tbl.has_y = ~isempty(tbl.axis_y);
  if tbl.has_y    
    tbl.size_y = numel(getfield(tbl,tbl.axis_y));
  else
    tbl.size_y = 0;
  end
  
  % store quantities names
  tbl.quant_names = quant_names(2:end);

end

function [tout,ax,ay] = correction_expand_tables(tin,reduce_axes)
% TWM: Expander of the correction tables loaded by 'correction_load_table'.
%
% This will take cell array of tables, looks for largest common range of 
% axes, then interpolates the tables data so all tables have the same axes.
% It uses selected interpolation mode and no extrapolation. NaNs will be inserted
% when range of new axis is outside range of source data.
% Note it will repeat the process for all data quantities in the table.
%
% Example: x_axis_1 = [1 2 3 5], x_axis_2 = [3 4 6] will result in new axis:
%          x_axis = [3 4 5]. The same for second axis.
% If the table is independent to one or both axes, the function lets
% them independent (will not create new axis).
%
% [tout,ax,xy] = correction_expand_tables(tin)
% [tout,ax,xy] = correction_expand_tables(tin, reduce_axes)
% [tout,ax,xy] = correction_expand_tables(..., i_mode)
%
% Parameters:
%  tin         - cell array of input tables
%  reduce_axes - reduces new axes to largest common range if set '1' (default)
%                if set to '0', it will merge the source axes to largest
%                needed range, but the data of some tables will contain NaNs!
%  i_mode      - interpolation mode (default: 'linear')
%
% Returns:
%  tout - cell array of the modfied tables
%  ax   - new x axis (empty if not exist)
%  ay   - new y axis (empty if not exist) 
%
%
% This is part of the TWM - TracePQM WattMeter (https://github.com/smaslan/TWM).
% (c) 2018, Stanislav Maslan, smaslan@cmi.cz
% The script is distributed under MIT license, https://opensource.org/licenses/MIT.                
% 

  % by default reduce axes to largest common range
  if ~exist('reduce_axes','var')
    reduce_axes = 1;
  end
  
  % identify interpolation mode:
  if ~exist('i_mode','var')
    if exist('reduce_axes','var') && ischar(reduce_axes)
      i_mode = reduce_axes;
    else
      i_mode = 'linear';
    end
  end
  
  % tables count
  T = numel(tin);
  
  % find unique x,y axis vlues for each table:
  ax = [];
  ay = [];
  ax_min = [];
  ax_max = [];
  ay_min = [];
  ay_max = [];
  for t = 1:T
    tab = tin{t};
    if tab.size_x
      xdata = getfield(tab,tab.axis_x);
      ax = union(ax,xdata);
      ax_min(end+1) = min(xdata);
      ax_max(end+1) = max(xdata);   
    end
    if tab.size_y
      ydata = getfield(tab,tab.axis_y);
      ay = union(ay,ydata);
      ay_min(end+1) = min(ydata);
      ay_max(end+1) = max(ydata); 
    end
  end
  % find largest common range of the axes:
  ax_min = max(ax_min);
  ax_max = min(ax_max);
  ay_min = max(ay_min);
  ay_max = min(ay_max);
  
  if reduce_axes
    % reduce output x,y axes ranges to largest common range:
    ax = ax(ax >= ax_min & ax <= ax_max);
    ay = ay(ay >= ay_min & ay <= ay_max);
  end
  
  % flip axes to right orientations:
  ax = ax(:).';
  ay = ay(:);
  
  % new axes have some items?
  has_x = ~~numel(ax);
  has_y = ~~numel(ay);
  
  % build meshgrid for 2D inetrpolation to the new axes:
  if has_x && has_y
    [axi,ayi] = meshgrid(ax,ay);
  end
  
  % --- now interpolate table data to new axes ---
  for t = 1:T
    % get one table:
    tab = tin{t};
    
    % get table's quantitites
    qnames = tab.quant_names;
    Q = numel(qnames);
    
    % load current axes
    if tab.size_x
      xdata = getfield(tab,tab.axis_x);
    end
    if tab.size_y
      ydata = getfield(tab,tab.axis_y);
    end
    
    % --- interpolate each quantity:
    for q = 1:Q
      if has_x && has_y && tab.size_x && tab.size_y
        % table has both axes, interpolate in 2D        
        qu = getfield(tab,qnames{q});
        qu = interp2nan(xdata,ydata,qu,axi,ayi,i_mode);
        tab = setfield(tab,qnames{q},qu);
      elseif has_y && tab.size_y
        % only primary axis (Y), interpolate 1D
        qu = getfield(tab,qnames{q});
        qu = interp1nan(ydata,qu,ay,i_mode);               
        tab = setfield(tab,qnames{q},qu);
      elseif has_x && tab.size_x
        % only secondary axis (X), interpolate 1D
        qu = getfield(tab,qnames{q});
        qu = interp1nan(xdata,qu,ax,i_mode);        
        tab = setfield(tab,qnames{q},qu); 
      end
    end
    
    % overwrite axes by new axes:
    if tab.has_x
      szx = numel(ax);
      if szx > 1
        tab = setfield(tab,tab.axis_x,ax);
      else
        tab = setfield(tab,tab.axis_x,[]);        
      end
      tab.size_x = (szx > 1)*szx;        
    end
    if tab.has_y
      szy = numel(ay);
      if szy > 1
        tab = setfield(tab,tab.axis_y,ay);
      else
        tab = setfield(tab,tab.axis_y,[]);
        tab.size_y = (szy > 1)*szy;
      end        
    end
    
    % return modified table table:
    tout{t} = tab;
    
  end
  
  % delete axes with just one item:
  if numel(ax) < 2
    ax = [];
  end
  if numel(ay) < 2
    ay = [];
  end

end

function [tbl] = correction_interp_table(tbl,ax,ay,new_axis_name,new_axis_dim,i_mode)
% TWM: Interpolator of the correction tables loaded by 'correction_load_table'.
% It will return interpolated value(s) from the correction table either in 2D
% mode or 1D mode.
% 
% Usage:
%   tbl = correction_interp_table(tbl, ax, [])
%   tbl = correction_interp_table(tbl, [], ay)
%   tbl = correction_interp_table(tbl, ax, ay)
%   tbl = correction_interp_table(tbl, ax, ay, new_axis_name, new_axis_dim)
%   tbl = correction_interp_table(..., i_mode)
%
%   tbl = correction_interp_table()
%     - run self-test/validation
%
% Parameters:
%   tbl           - Input table
%   ax            - 1D vector of the new x-axis values (optional)
%   ay            - 1D vector of the new y-axis values (optional)
%   new_axis_name - If non-empty, the interpolation will be in 1D (optional)
%                   in this case the 'ax' and 'ay' must have the same size
%                   or one may be vector and one scalar, the scalar one will
%                   be replicated to size of the other. The function will 
%                   return 1 item per item of 'ax'/'ay'
%                   It will also create a new 1D table with the one axis name
%                   'new_axis_name'.
%   new_axis_dim  - In the 1D mode this defines which axis 'ax' or 'ay' will be
%                   used for the new axis 'new_axis_name'.
%   interp_mode   - Desired mode of interpolation same as for interp1(),
%                   default is 'linear'.  
%
% note: leave 'ax' or 'ay' empty [] to not interpolate in that axis.
% note: if the 'ax' or 'ay' is not empty and the table have not x or y
% axis it will return an error.  
%
% Returns:
%   tbl - table with interpolated quantities
%
% This is part of the TWM - TracePQM WattMeter.
% (c) 2018, Stanislav Maslan, smaslan@cmi.cz
% The script is distributed under MIT license, https://opensource.org/licenses/MIT.                
% 
    
    % default parameters:
    if ~exist('ax','var')
        ax = [];
    end
    if ~exist('ay','var')
        ay = [];
    end

    % desired axes to interpolate:
    has_ax = ~isempty(ax);
    has_ay = ~isempty(ay);
    
    if has_ax && ~isvector(ax)
        error('Correction table interpolator: Axis X is not a vector!');
    end
    if has_ay && ~isvector(ay)
        error('Correction table interpolator: Axis Y is not a vector!');
    end
    
    % is it 2D interpolation?
    in2d = ~(exist('new_axis_name','var') && exist('new_axis_dim','var'));
    
    % input checking for the 2D mode
    if ~in2d
        
        if ~has_ax || ~has_ay 
            error('Correction table interpolator: 2D interpolation requsted, but some of the new axes is empty?');
        end
        
        if numel(ax) > 1 && numel(ay) > 1 && numel(ax) ~= numel(ay)
            error('Correction table interpolator: Both axes must have the same items count or one must be scalar!');
        end
        
        % expand axes:
        if isscalar(ay) && ~isvector(ax)
            if new_axis_dim == 2
                ay = repmat(ay,size(ax));
            else
                error('Correction table interpolator: Cannot expand axis ''ay'' because the ''new_axis_dim'' requests this axis as a new independnet axis of the table!');
            end
        elseif isscalar(ax) && ~isvector(ay)
            if new_axis_dim == 1
                ax = repmat(ax,size(ay));
            else
                error('Correction table interpolator: Cannot expand axis ''ax'' because the ''new_axis_dim'' requests this axis as a new independnet axis of the table!');
            end            
        end
        
    elseif exist('new_axis_name','var')
        % get interpolation mode:
        i_mode = new_axis_name;
    end
    
    if ~exist('i_mode','var')
        i_mode = 'linear'; % default interp mode
    end
    
    % check compatibility with data:
    if has_ax && ~tbl.has_x
        error('Correction table interpolator: Interpolation by nonexistent axis X required!');
    end
    if has_ay && ~tbl.has_y
        error('Correction table interpolator: Interpolation by nonexistent axis Y required!');    
    end
    
    % original independent axes data:
    if tbl.has_x
        ox = getfield(tbl,tbl.axis_x);
    else
        ox = [];
    end
    if tbl.has_y
        oy = getfield(tbl,tbl.axis_y);
    else
        oy = [];
    end
        
    % if interpolation axis data 'ax' and/or 'ay' are not defined, return all table's elements in that axis/axes: 
    if isempty(ax)
        ax = ox;
    end
    if isempty(ay)
        ay = oy;
    end
    
    % count of the quantities in the table:
    q_names = tbl.quant_names;
    Q = numel(tbl.quant_names);
    
    % load all quantities:
    quants = {};
    for q = 1:Q
        quants{end+1} = getfield(tbl,q_names{q});
    end

    
    % flip axes to proper orientation:
    ax = ax(:).';
    ay = ay(:);
    
    if ~in2d
        % --- mode 1: one value per item of 'ax'/'ay':
        
    
        % interpolate each quantity:
        if tbl.size_x && tbl.size_y
            for q = 1:Q
                quants{q} = interp2nan(ox,oy,quants{q},ax.',ay,i_mode);
            end
        elseif tbl.size_x
            for q = 1:Q
                quants{q} = interp1nan(ox,quants{q},ax,i_mode);
            end
        elseif tbl.size_y
            for q = 1:Q
                quants{q} = interp1nan(oy,quants{q},ay,i_mode);
            end
        else
            if new_axis_dim == 1
                for q = 1:Q
                    quants{q} = repmat(quants{q},size(ay));
                end
            else
                for q = 1:Q
                    quants{q} = repmat(quants{q},size(ax));
                end
            end            
        end
        
        % set correct orientation:
        if new_axis_dim == 1
            for q = 1:Q
                quants{q} = quants{q}(:);
            end
        else
            for q = 1:Q
                quants{q} = quants{q}(:).';
            end    
        end
        
        % --- modify the axes, because not it became just 1D table dependent on unknown new axis:
        
        % remove original axes of the table:
        tbl = rmfield(tbl,{tbl.axis_x, tbl.axis_y});

        % create new axis:
        if new_axis_dim == 1
            % select 'ay' as the new axis:
            tbl.axis_x = '';
            tbl.axis_y = new_axis_name;
            tbl.has_x = 0;
            tbl.has_y = 1;
        else
            % select 'ax' as the new axis:
            tbl.axis_x = new_axis_name;
            tbl.axis_y = '';
            tbl.has_x = 1;
            tbl.has_y = 0;
        end        
    
    else
        % --- mode 2: regular 2D interpolation:
        
        if ~isempty(ax) && ~isempty(ay)
            if tbl.size_x && tbl.size_y
                for q = 1:Q
                    quants{q} = interp2nan(ox,oy,quants{q},ax,ay,i_mode);
                end
            elseif tbl.size_x
                for q = 1:Q
                    quants{q} = repmat(interp1nan(ox,quants{q},ax),size(ay));
                end
            elseif tbl.size_y
                for q = 1:Q
                    quants{q} = repmat(interp1nan(oy,quants{q},ay),size(ax));
                end
            else
                for q = 1:Q
                    quants{q} = repmat(quants{q},[numel(ay) numel(ax)]);
                end
            end        
        elseif ~isempty(ax)
            if tbl.size_x
                for q = 1:Q
                    quants{q} = interp1nan(ox,quants{q},ax,i_mode);
                end
            else
                for q = 1:Q
                    quants{q} = repmat(quants{q},size(ax));
                end
            end        
        elseif ~isempty(ay)
            if tbl.size_y
                for q = 1:Q
                    quants{q} = interp1nan(oy,quants{q},ay,i_mode);
                end
            else
                for q = 1:Q
                    quants{q} = repmat(quants{q},size(ay));
                end
            end        
        end 
    end  
    
    % store back the interpolated quantities:
    for q = 1:Q
        tbl = setfield(tbl,q_names{q},quants{q});
    end
        
    % set interpolated table's flags@stuff:
    szx = size(quants{1},2)*(~~numel(quants{1}));
    szy = size(quants{1},1)*(~~numel(quants{1}));    
    tbl.size_x = (szx > 1)*szx;
    tbl.size_y = (szy > 1)*szy;
    if ~tbl.has_x && tbl.size_x 
        tbl.axis_x = 'ax';    
    end
    if ~tbl.has_y && tbl.size_y 
        tbl.axis_y = 'ay';    
    end    
    tbl.has_x = tbl.has_x | szx > 1;
    tbl.has_y = tbl.has_y | szy > 1;
    
    % store new x and y axis data:
    if szx < 2
        ax = [];
    end
    if szy < 2
        ay = [];
    end
    if tbl.has_x 
        tbl = setfield(tbl,tbl.axis_x,ax);
    end
    if tbl.has_y
        tbl = setfield(tbl,tbl.axis_y,ay);
    end


end

% ====== SUB-FUNCTIONS SECTION ======

function [yi] = interp1nan(x,y,xi,varargin)
% This is a crude wrapper for interp1() function that should avoid unwanted NaN
% results if the 'xi' is on the boundary of NaN data in 'y'.
%
% Note: Not all parameter combinations for interp1() are implemented!
%       It is just very basic wrapper.
%
% Example:
% x = [1 2 3], y = [1 2 NaN]
% interp1(x,y,2,'linear') may return NaN because the 'xi = 2' is on the boundary
% of the valid 'y' data.  
%
% This is part of the TWM - TracePQM WattMeter.
% (c) 2018, Stanislav Maslan, smaslan@cmi.cz
% The script is distributed under MIT license, https://opensource.org/licenses/MIT.                
% 

    % maximum allowable tolerance: 
    max_eps = 5*eps*xi;
    
    % try to interpolate with offsets xi = <xi +/- max_eps>:
    tmp(:,:,1) = interp1(x,y,xi + max_eps,varargin{:});
    tmp(:,:,2) = interp1(x,y,xi - max_eps,varargin{:});
    
    % select non NaN results from the candidates:
    yi = nanmean(tmp,3);    

end

function [zi] = interp2nan(x,y,z,xi,yi,varargin)
% This is a crude wrapper for interp2() function that should avoid unwanted NaN
% results if the 'xi' or 'yi' is on the boundary of NaN data in 'z'.
%
% Note: Not all parameter combinations for interp2() are implemented!
%       It is just very basic wrapper.
%
% Example:
% x = [1 2 3]
% y = [1;2;3]
% z = [1 2 3;
%      4 5 6;
%      7 8 NaN]
% interp2(x,y,z,3,2,'linear') may return NaN because the 'xi = 2' and 'yi = 3' 
% is on the boundary of the valid 'z' data.  
%
% This is part of the TWM - TracePQM WattMeter.
% (c) 2018, Stanislav Maslan, smaslan@cmi.cz
% The script is distributed under MIT license, https://opensource.org/licenses/MIT.                
% 

    % maximum allowable tolerance: 
    max_eps_x = 5*eps*xi;
    max_eps_y = 5*eps*yi;
    
    % try to interpolate with offsets xi = <xi +/- max_eps>, yi = <yi +/- max_eps>:
    tmp(:,:,1) = interp2(x,y,z,xi + max_eps_x,yi + max_eps_y,varargin{:});
    tmp(:,:,2) = interp2(x,y,z,xi + max_eps_x,yi - max_eps_y,varargin{:});
    tmp(:,:,3) = interp2(x,y,z,xi - max_eps_x,yi - max_eps_y,varargin{:});
    tmp(:,:,4) = interp2(x,y,z,xi - max_eps_x,yi + max_eps_y,varargin{:});
    
    % select non NaN results from the candidates:
    zi = nanmean(tmp,3);    

end

