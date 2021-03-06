% [INPUT]
% data = A structure representing the dataset.
% out_temp = A string representing the full path to the Excel spreadsheet used as a template for the results file.
% out_file = A string representing the full path to the Excel spreadsheet to which the results are written, eventually replacing the previous ones.
% k = A float [0.90,0.99] representing the confidence level used to calculate CoVaR, Delta CoVaR, MES and LRMES (optional, default=0.95).
% d = A float [0.10,0.60] representing the six-month crisis threshold for the market index decline used to calculate LRMES (optional, default=0.40).
% l = A float [0.03,0.20] representing the capital adequacy ratio used to calculate SRISK (optional, default=0.08).
% s = A float [0.00,1.00] representing the fraction of separate accounts, if available, to include in liabilities during the SRISK calculation (optional, default=0.40).
% analyze = A boolean that indicates whether to analyse the results and display plots (optional, default=false).
%
% [OUTPUT]
% result = A structure representing the original dataset inclusive of intermediate and final calculations.

function result = run_cross_sectional(varargin)

    persistent ip;

    if (isempty(ip))
        ip = inputParser();
        ip.addRequired('data',@(x)validateattributes(x,{'struct'},{'nonempty'}));
        ip.addRequired('out_temp',@(x)validateattributes(x,{'char'},{'nonempty','size',[1,NaN]}));
        ip.addRequired('out_file',@(x)validateattributes(x,{'char'},{'nonempty','size',[1,NaN]}));
        ip.addOptional('k',0.95,@(x)validateattributes(x,{'double','single'},{'scalar','real','finite','>=',0.90,'<=',0.99}));
        ip.addOptional('d',0.40,@(x)validateattributes(x,{'double','single'},{'scalar','real','finite','>=',0.10,'<=',0.60}));
        ip.addOptional('l',0.08,@(x)validateattributes(x,{'double','single'},{'scalar','real','finite','>=',0.03,'<=',0.20}));
        ip.addOptional('s',0.40,@(x)validateattributes(x,{'double','single'},{'scalar','real','finite','>=',0.00,'<=',1.00}));
        ip.addOptional('analyze',false,@(x)validateattributes(x,{'logical'},{'scalar'}));
    end

    ip.parse(varargin{:});

    ipr = ip.Results;
    data = validate_data(ipr.data);
    out_temp = validate_template(ipr.out_temp);
    out_file = validate_output(ipr.out_file);

    result = run_cross_sectional_internal(data,out_temp,out_file,ipr.k,ipr.d,ipr.l,ipr.s,ipr.analyze);

end

function result = run_cross_sectional_internal(data,out_temp,out_file,k,d,l,s,analyze)

    result = [];
    
    bar = waitbar(0,'Calculating cross-sectional measures...','CreateCancelBtn',@(src,event)setappdata(gcbf(),'Stop', true));
    setappdata(bar,'Stop',false);

    data = data_initialize(data,k,d,l,s);
    
    r_m = data.IndexReturns;
    r0_m = r_m - mean(r_m);
    
    stopped = false;
    e = [];

    try
        for i = 1:data.N
            waitbar((i - 1) / data.N,bar,['Calculating cross-sectional measures for ' data.FirmNames{i} '...']);

            if (getappdata(bar,'Stop'))
                stopped = true;
                break;
            end
            
            r_x = data.FirmReturns(:,i);
            r0_x = r_x - mean(r_x);

            [p,h] = dcc_gjrgarch([r0_m r0_x]);
            s_m = sqrt(h(:,1));
            s_x = sqrt(h(:,2));
            rho = squeeze(p(1,2,:));

            beta = rho .* (s_x ./ s_m);
            var = s_x * quantile((r0_x ./ s_x),data.A);

            [covar,dcovar] = calculate_covar(data.A,r0_m,r0_x,var,data.StateVariables);
            [mes,lrmes] = calculate_mes(data.A,data.D,r0_m,s_m,r0_x,s_x,rho,beta);
            srisk = calculate_srisk(data.L,data.S,lrmes,data.Liabilities(:,i),data.Capitalizations(:,i),data.SeparateAccounts(:,i));

            data.Beta(:,i) = beta;
            data.VaR(:,i) = -1 .* var;
            data.CoVaR(:,i) = -1 .* covar;
            data.DeltaCoVaR(:,i) = -1 .* dcovar;
            data.MES(:,i) = -1 .* mes;
            data.SRISK(:,i) = srisk;
            
            if (getappdata(bar,'Stop'))
                stopped = true;
                break;
            end
            
            waitbar(i / data.N,bar);
        end
    catch e
    end

    if (~isempty(e))
        delete(bar);
        rethrow(e);
    end
    
    if (stopped)
        delete(bar);
        return;
    end
    
    data = data_finalize(data);

    waitbar(100,bar,'Writing cross-sectional measures...');
    write_results(out_temp,out_file,data);
    delete(bar);
    
    if (analyze)
        plot_averages(data);
        plot_correlations(data);
    end
    
    result = data;

end

%% DATA

function data = data_initialize(data,k,d,l,s)
  
    data.A = 1 - k;
    data.D = d;
    data.K = k;
    data.L = l;
    data.S = s;

    d_label = sprintf('%.0f%%',(data.D * 100));
    k_label = sprintf('%.0f%%',(data.K * 100));
    l_label = sprintf('%.0f%%',(data.L * 100));
    s_label = sprintf('%.0f%%',(data.S * 100));
    data.Labels = {'Beta' ['VaR (k=' k_label ')'] ['CoVaR (k=' k_label ')'] ['Delta CoVaR (k=' k_label ')'] ['MES (k=' k_label ')'] ['SRISK (d=' d_label ', l=' l_label ', s=' s_label ')'] 'Averages'};
    data.LabelsSimple = {'Beta' 'VaR' 'CoVaR' 'Delta CoVaR' 'MES' 'SRISK' 'Averages'};  
    
    data.Beta = NaN(data.T,data.N);
    data.VaR = NaN(data.T,data.N);
    data.CoVaR = NaN(data.T,data.N);
    data.DeltaCoVaR = NaN(data.T,data.N);
    data.MES = NaN(data.T,data.N);
    data.SRISK = NaN(data.T,data.N);

end

function data = data_finalize(data)

    factors = sum(data.Capitalizations,2);
    weights = data.CapitalizationsLagged ./ repmat(sum(data.CapitalizationsLagged,2),1,data.N);

    beta_avg = sum(data.Beta .* weights,2) .* factors;
    var_avg = sum(data.VaR .* weights,2) .* factors;
    covar_avg = sum(data.CoVaR .* weights,2) .* factors;
    dcovar_avg = sum(data.DeltaCoVaR .* weights,2) .* factors;
    mes_avg = sum(data.MES .* weights,2) .* factors;
    srisk_avg = sum(data.SRISK .* weights,2);

    data.Averages = [beta_avg var_avg covar_avg dcovar_avg mes_avg srisk_avg];

end

function data = validate_data(data)

    fields = {'Full', 'T', 'N', 'DatesNum', 'DatesStr', 'MonthlyTicks', 'IndexName', 'IndexReturns', 'FirmNames', 'FirmReturns', 'Capitalizations', 'CapitalizationsLagged', 'Liabilities', 'SeparateAccounts', 'StateVariables', 'Groups', 'GroupDelimiters', 'GroupNames'};
    
    for i = 1:numel(fields)
        if (~isfield(data,fields{i}))
            error('The dataset does not contain all the required data.');
        end
    end
    
    if (~data.Full)
        error('The dataset does not contain market capitalization and total liabilities time series, cross-sectional measures cannot be calculated.');
    end
    
end

function out_file = validate_output(out_file)

    [path,name,extension] = fileparts(out_file);

    if (~strcmp(extension,'.xlsx'))
        out_file = fullfile(path,[name extension '.xlsx']);
    end
    
end

function out_temp = validate_template(out_temp)

    if (exist(out_temp,'file') == 0)
        error('The template file could not be found.');
    end
    
    if (ispc())
        [file_status,file_sheets,file_format] = xlsfinfo(out_temp);
        
        if (isempty(file_status) || ~strcmp(file_format,'xlOpenXMLWorkbook'))
            error('The template file is not a valid Excel spreadsheet.');
        end
    else
        [file_status,file_sheets] = xlsfinfo(out_temp);
        
        if (isempty(file_status))
            error('The template file is not a valid Excel spreadsheet.');
        end
    end

    sheets = {'CoVaR' 'Delta CoVaR' 'MES' 'SRISK' 'Averages'};
    
    if (~all(ismember(sheets,file_sheets)))
        error(['The template must contain the following sheets: ' sheets{1} sprintf(', %s', sheets{2:end}) '.']);
    end
    
    if (ispc())
        try
            excel = actxserver('Excel.Application');
            excel_wb = excel.Workbooks.Open(out_temp,0,false);

            for i = 1:numel(sheets)
                excel_wb.Sheets.Item(sheets{i}).Cells.Clear();
            end
            
            excel_wb.Save();
            excel_wb.Close();
            excel.Quit();

            delete(excel);
        catch
        end
    end

end

function write_results(out_temp,out_file,data)

    [out_file_path,~,~] = fileparts(out_file);

    if (exist(out_file_path,'dir') ~= 7)
        mkdir(out_file_path);
    end

    if (exist(out_file,'file') == 2)
        delete(out_file);
    end
    
    copy_result = copyfile(out_temp,out_file,'f');
    
    if (copy_result == 0)
        error('The results file could not be created from the template file.');
    end

    dates_str = cell2table(data.DatesStr,'VariableNames',{'Date'});

    t1 = [dates_str array2table(data.CoVaR,'VariableNames',data.FirmNames)];
    writetable(t1,out_file,'FileType','spreadsheet','Sheet','CoVaR','WriteRowNames',true);

    t2 = [dates_str array2table(data.DeltaCoVaR,'VariableNames',data.FirmNames)];
    writetable(t2,out_file,'FileType','spreadsheet','Sheet','Delta CoVaR','WriteRowNames',true);
    
    t3 = [dates_str array2table(data.MES,'VariableNames',data.FirmNames)];
    writetable(t3,out_file,'FileType','spreadsheet','Sheet','MES','WriteRowNames',true);

    t4 = [dates_str array2table(data.SRISK,'VariableNames',data.FirmNames)];
    writetable(t4,out_file,'FileType','spreadsheet','Sheet','SRISK','WriteRowNames',true);  
    
    t5 = [dates_str array2table(data.Averages(:,3:end),'VariableNames',strrep(data.LabelsSimple(3:end-1),' ','_'))];
    writetable(t5,out_file,'FileType','spreadsheet','Sheet','Averages','WriteRowNames',true);    

    if (ispc())
        try
            excel = actxserver('Excel.Application');
            exc_wb = excel.Workbooks.Open(out_file,0,false);

            exc_wb.Sheets.Item('CoVaR').Name = data.Labels{3};
            exc_wb.Sheets.Item('Delta CoVaR').Name = data.Labels{4};
            exc_wb.Sheets.Item('MES').Name = data.Labels{5};
            exc_wb.Sheets.Item('SRISK').Name = data.Labels{6};
            
            exc_wb.Save();
            exc_wb.Close();
            excel.Quit();
            
            delete(excel);
        catch
        end
    end

end

%% MEASURES

function [covar,dcovar] = calculate_covar(a,r0_m,r0_x,var,state_variables)

    if (isempty(state_variables))
        beta = quantile_regression(r0_m,r0_x,a);
        covar = beta(1) + (beta(2) .* var);
    else
        beta = quantile_regression(r0_m,[r0_x state_variables],a);
        covar = beta(1) + (beta(2) .* var);

        for i = 1:size(state_variables,2)
            covar = covar + (beta(i+2) .* state_variables(:,i));
        end
    end

	dcovar = beta(2) .* (var - repmat(median(r0_x),length(r0_m),1));

end

function [mes,lrmes] = calculate_mes(a,d,r0_m,s_m,r0_x,s_x,rho,beta)

    c = quantile(r0_m,a);
    z = sqrt(1 - (rho .^ 2));

    u = r0_m ./ s_m;
    x = ((r0_x ./ s_x) - (rho .* u)) ./ z;

    r0_n = 4 / (3 * length(r0_m));
    r0_s = min([std(r0_m) (iqr(r0_m) / 1.349)]);
    h = r0_s * (r0_n ^ (-0.2));

    f = normcdf(((c ./ s_m) - u) ./ h);
    f_sum = sum(f);

    k1 = sum(u .* f) ./ f_sum;
    k2 = sum(x .* f) ./ f_sum;

    mes = (s_x .* rho .* k1) + (s_x .* z .* k2);
    lrmes = 1 - exp(log(1 - d) .* beta);

end

function srisk = calculate_srisk(l,s,lrmes,liabilities,equity,separate_accounts)

    if (~isnan(separate_accounts))
        liabilities = liabilities - ((1 - s) .* separate_accounts);
    end

    srisk = (l .* liabilities) - ((1 - l) .* (1 - lrmes) .* equity);
    srisk(srisk < 0) = 0;

end

function beta = quantile_regression(y,x,k)

    [n,m] = size(x);
    m = m + 1;

    x = [ones(n,1) x];
    x_star = x;

    beta = ones(m,1);

    diff = 1;
    iter = 0;

    while ((diff > 1e-6) && (iter < 1000))
        x_star_t = x_star.';
        beta_0 = beta;

        beta = ((x_star_t * x) \ x_star_t) * y;

        residuals = y - (x * beta);
        residuals(abs(residuals) < 0.000001) = 0.000001;
        residuals(residuals < 0) = k * residuals(residuals < 0);
        residuals(residuals > 0) = (1 - k) * residuals(residuals > 0);
        residuals = abs(residuals);

        z = zeros(n,m);

        for i = 1:m 
            z(:,i) = x(:,i) ./ residuals;
        end

        x_star = z;
        beta_1 = beta;
        
        diff = max(abs(beta_1 - beta_0));
        iter = iter + 1;
    end

end

%% PLOTTING

function plot_averages(data)

    averages = data.Averages(:,3:end);
    averages_len = size(averages,2);

    x_max = max(max(averages));
    x_max_sign = sign(x_max);
    x_min = min(min(averages));
    x_min_sign = sign(x_min);
    y_limits = [((abs(x_min) * 1.1) * x_min_sign) ((abs(x_max) * 1.1) * x_max_sign)];

    f = figure('Name','Cross-Sectional Measures Averages','Units','normalized','Position',[100 100 0.85 0.85]);

    subs = NaN(averages_len,1);
    
    for i = 1:averages_len
        sub = subplot(2,2,i);
        plot(sub,data.DatesNum,averages(:,i));
        xlabel(sub,'Time');
        ylabel(sub,'Value');
        set(sub,'XLim',[data.DatesNum(1) data.DatesNum(end)],'YLim',y_limits,'XTickLabelRotation',45);
        title(sub,data.Labels(i+2));
        
        if (data.MonthlyTicks)
            datetick(sub,'x','mm/yyyy','KeepLimits','KeepTicks');
        else
            datetick(sub,'x','yyyy','KeepLimits');
        end
        
        subs(i) = sub;
    end

    y_labels = arrayfun(@(x)sprintf('%.0f',x),get(subs(end),'YTick'),'UniformOutput',false);
    set(subs,'YTickLabel',y_labels);
    
    t = figure_title('Cross-Sectional Measures Averages');
    t_position = get(t,'Position');
    set(t,'Position',[t_position(1) -0.0157 t_position(3)]);

    pause(0.01);
    frame = get(f,'JavaFrame');
    set(frame,'Maximized',true);

end

function plot_correlations(data)

    [rho,pval] = corr(data.Averages);
    m = mean(data.Averages);
    s = std(data.Averages);

    z = bsxfun(@minus,data.Averages,m);
    z = bsxfun(@rdivide,z,s);
    z_limits = [nanmin(z(:)) nanmax(z(:))];

    f = figure('Name','Cross-Sectional Measures Correlation Matrix','Units','normalized');
    
    pause(0.01);
    frame = get(f,'JavaFrame');
    set(frame,'Maximized',true);

    pause(0.01);
    set(0,'CurrentFigure',f);
    [handles,axes,big_axes] = gplotmatrix(data.Averages,[],[],[],'o',2,[],'hist',data.LabelsSimple(1:end-1),data.LabelsSimple(1:end-1));
    set(handles(logical(eye(size(data.Averages,2)))),'FaceColor',[0.678 0.922 1]);
    
    drawnow();

    x_labels = get(axes,'XLabel');
    y_labels = get(axes,'YLabel');
    set([x_labels{:}; y_labels{:}],'FontWeight','bold');

    for i = 1:6
        for j = 1:6
            ax_ij = axes(i,j);
            
            z_limits_current = 1.1 .* z_limits;
            x_limits = m(j) + (z_limits_current * s(j));
            y_limits = m(i) + (z_limits_current * s(i));
            
            set(get(big_axes,'Parent'),'CurrentAxes',ax_ij);
            set(ax_ij,'XLim',x_limits,'XTick',[],'YLim',y_limits,'YTick',[]);
            axis normal;
            
            if (i ~= j)
                line = lsline();
                set(line,'Color','r');

                if (pval(i,j) < 0.05)
                    color = 'r';
                else
                    color = 'k';
                end

                annotation('TextBox',get(ax_ij,'Position'),'String',num2str(rho(i,j),'%.2f'),'Color',color,'EdgeColor','none','FontWeight','Bold');
            end
        end
    end

    annotation('TextBox',[0 0 1 1],'String','Cross-Sectional Measures Correlation Matrix','EdgeColor','none','FontName','Helvetica','FontSize',14,'HorizontalAlignment','center');

end
