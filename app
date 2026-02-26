"""
German BESS Financing Structures Calculator v4
Modo Energy · Article 4: Building Bankable Business Cases

Compare four German BESS financing structures across three revenue scenarios.
"""

# ── 1. Imports ──────────────────────────────────────────────────────────────
import streamlit as st
import plotly.graph_objects as go
import numpy_financial as npf
import numpy as np

# ── 2. Constants and data ───────────────────────────────────────────────────
CAPEX = 690           # €k/MW total installed cost
OPEX = 10             # €k/MW/yr operating cost
EURIBOR = 2.25        # % base rate
SIZING_TENOR = 14     # years lenders size debt over (15yr life − 1yr buffer)
LOAN_TENOR = 7        # years mini-perm maturity — FIXED
PROJECT_LIFE = 15     # years total project life
BALLOON_PCT = 40      # % of original debt remaining at year 7
HURDLE_RATE = 10      # % equity IRR threshold
ANCHOR_MERCHANT = dict(gearing=45, margin_bps=313, dscr=2.0)
ANCHOR_CONTRACTED = dict(gearing=80, margin_bps=203, dscr=1.18)

REVENUE_TOTAL = {
    'low':  [99, 83, 78, 74, 74, 74, 76, 75, 71, 73, 77, 80, 84, 84, 84],
    'base': [155, 129, 123, 119, 117, 118, 118, 117, 114, 115, 119, 119, 118, 114, 114],
    'high': [211, 175, 169, 164, 161, 162, 161, 159, 158, 158, 161, 158, 152, 144, 144],
}

REVENUE_DA = {
    'low':  [37, 29, 27, 27, 27, 27, 27, 27, 27, 28, 31, 30, 32, 32, 32],
    'base': [61, 49, 47, 47, 46, 47, 46, 47, 47, 48, 51, 50, 49, 49, 49],
    'high': [81, 64, 62, 62, 61, 62, 61, 61, 63, 64, 66, 62, 61, 58, 58],
}

STRUCTURE_COLOURS = {
    'merchant':    '#888888',
    'full_toll':   '#1a7a6e',
    'floor_share': '#2196a8',
    'da_swap':     '#5c6bc0',
}

STRUCTURE_LABELS = {
    'merchant':    'Merchant',
    'full_toll':   'Full Toll',
    'floor_share': 'Floor + Share',
    'da_swap':     'DA Swap',
}

DEFAULTS = {
    'merchant': {'gearing': 45},
    'full_toll': {'toll_price': 105, 'toll_pct': 80, 'toll_tenor': 7},
    'floor_share': {'floor_price': 85, 'floor_pct': 80, 'upside_share': 20, 'toll_tenor': 7},
    'da_swap': {'da_fixed_leg': 45, 'da_swap_pct': 100, 'toll_tenor': 10},
}

# Colours
TEAL = '#1a7a6e'
TEAL_LIGHT = '#e8f4f2'
DARK = '#1a1a1a'
MID = '#666666'
GREY_BG = '#f8f8f8'
GREEN = '#2e7d32'
AMBER = '#e65100'
RED = '#c62828'

# ── 3. Core calculation functions ───────────────────────────────────────────

def get_fixed_fraction(guaranteed_annual_revenue_k_per_mw):
    LOW_CASE_ANCHOR = 99
    return min(guaranteed_annual_revenue_k_per_mw / LOW_CASE_ANCHOR, 1.0)


def interpolate_financing(fixed_fraction):
    t = fixed_fraction
    gearing = ANCHOR_MERCHANT['gearing'] + t * (ANCHOR_CONTRACTED['gearing'] - ANCHOR_MERCHANT['gearing'])
    margin_bps = ANCHOR_MERCHANT['margin_bps'] + t * (ANCHOR_CONTRACTED['margin_bps'] - ANCHOR_MERCHANT['margin_bps'])
    dscr = ANCHOR_MERCHANT['dscr'] + t * (ANCHOR_CONTRACTED['dscr'] - ANCHOR_MERCHANT['dscr'])
    return round(gearing, 1), round(margin_bps, 0), round(dscr, 2)


def revenue_merchant(i, scenario):
    return REVENUE_TOTAL[scenario][i]


def revenue_full_toll(i, scenario, toll_price, toll_pct, toll_tenor):
    if i < toll_tenor:
        contracted = toll_price * (toll_pct / 100)
        uncontracted = REVENUE_TOTAL[scenario][i] * (1 - toll_pct / 100)
        return contracted + uncontracted
    else:
        return REVENUE_TOTAL[scenario][i]


def revenue_floor_share(i, scenario, floor_price, floor_pct, upside_share_pct, toll_tenor):
    market = REVENUE_TOTAL[scenario][i]
    if i < toll_tenor:
        if market >= floor_price:
            excess = market - floor_price
            protected_rev = floor_price + excess * (1 - upside_share_pct / 100)
        else:
            protected_rev = floor_price
        developer_rev = protected_rev * (floor_pct / 100) + market * (1 - floor_pct / 100)
    else:
        developer_rev = market
    return developer_rev


def revenue_da_swap(i, scenario, da_fixed_leg, da_swap_pct, toll_tenor):
    da_actual = REVENUE_DA[scenario][i]
    ancillary = REVENUE_TOTAL[scenario][i] - da_actual
    if i < toll_tenor:
        da_hedged = da_fixed_leg * (da_swap_pct / 100)
        da_unhedged = da_actual * (1 - da_swap_pct / 100)
        return da_hedged + da_unhedged + ancillary
    else:
        return REVENUE_TOTAL[scenario][i]


def get_capital(gearing_pct):
    debt = CAPEX * gearing_pct / 100
    equity = CAPEX - debt
    return debt, equity


def build_debt_service(debt_k, margin_bps):
    all_in_rate = (EURIBOR + margin_bps / 100) / 100
    balloon = debt_k * BALLOON_PCT / 100
    principal_yrs_1_7 = (debt_k - balloon) / LOAN_TENOR
    principal_yrs_8_14 = balloon / (SIZING_TENOR - LOAN_TENOR)

    schedule = []
    outstanding = debt_k
    for _ in range(LOAN_TENOR):
        interest = outstanding * all_in_rate
        ds = principal_yrs_1_7 + interest
        schedule.append(ds)
        outstanding -= principal_yrs_1_7
    for _ in range(SIZING_TENOR - LOAN_TENOR):
        interest = outstanding * all_in_rate
        ds = principal_yrs_8_14 + interest
        schedule.append(ds)
        outstanding -= principal_yrs_8_14
    schedule.append(0.0)
    return schedule


def calc_returns(revenue_series, debt_service, equity_k, dscr_target, toll_tenor):
    net_op = [rev - OPEX for rev in revenue_series]

    dscr_series = []
    for i in range(SIZING_TENOR):
        ds = debt_service[i]
        dscr_series.append(net_op[i] / ds if ds > 0 else 99.0)

    min_dscr = min(dscr_series)
    min_dscr_year = dscr_series.index(min_dscr) + 1
    in_contracted = min_dscr_year <= toll_tenor
    feasible = min_dscr >= dscr_target

    equity_cf = [net_op[i] - debt_service[i] for i in range(PROJECT_LIFE)]
    irr_raw = npf.irr([-equity_k] + equity_cf)
    irr = float(irr_raw * 100) if not np.isnan(irr_raw) else -99.0

    return {
        'irr': round(irr, 1),
        'min_dscr': round(min_dscr, 2),
        'min_dscr_year': min_dscr_year,
        'in_contracted': in_contracted,
        'dscr_series': [round(d, 2) for d in dscr_series],
        'net_op': net_op,
        'feasible': feasible,
    }


def run_structure(name, revenue_fn_dict, gearing_pct, margin_bps, dscr_target, toll_tenor):
    debt_k, equity_k = get_capital(gearing_pct)
    ds = build_debt_service(debt_k, margin_bps)
    all_in_rate = (EURIBOR + margin_bps / 100) / 100

    scenarios = {}
    for s in ['low', 'base', 'high']:
        scenarios[s] = calc_returns(revenue_fn_dict[s], ds, equity_k, dscr_target, toll_tenor)

    feasible = scenarios['low']['feasible']

    return {
        'name': name,
        'gearing': gearing_pct,
        'margin_bps': margin_bps,
        'all_in_rate': round(all_in_rate * 100, 2),
        'dscr_target': dscr_target,
        'debt_k': round(debt_k, 1),
        'equity_k': round(equity_k, 1),
        'debt_service': ds,
        'scenarios': scenarios,
        'feasible': feasible,
    }


def build_revenue_series(structure, params):
    series = {}
    for s in ['low', 'base', 'high']:
        if structure == 'merchant':
            series[s] = [revenue_merchant(i, s) for i in range(PROJECT_LIFE)]
        elif structure == 'full_toll':
            series[s] = [revenue_full_toll(i, s, params['toll_price'],
                                           params['toll_pct'], params['toll_tenor'])
                         for i in range(PROJECT_LIFE)]
        elif structure == 'floor_share':
            series[s] = [revenue_floor_share(i, s, params['floor_price'],
                                             params['floor_pct'], params['upside_share'],
                                             params['toll_tenor'])
                         for i in range(PROJECT_LIFE)]
        elif structure == 'da_swap':
            series[s] = [revenue_da_swap(i, s, params['da_fixed_leg'],
                                         params['da_swap_pct'], params['toll_tenor'])
                         for i in range(PROJECT_LIFE)]
    return series


def compute_structure_defaults(structure_key):
    """Compute financing params and results for a structure at default inputs."""
    params = DEFAULTS[structure_key]
    toll_tenor = params.get('toll_tenor', PROJECT_LIFE)

    if structure_key == 'merchant':
        guaranteed = 0
    elif structure_key == 'full_toll':
        guaranteed = params['toll_price'] * (params['toll_pct'] / 100)
    elif structure_key == 'floor_share':
        guaranteed = params['floor_price'] * (params['floor_pct'] / 100)
    elif structure_key == 'da_swap':
        guaranteed = params['da_fixed_leg'] * (params['da_swap_pct'] / 100)

    ff = get_fixed_fraction(guaranteed)
    gearing, margin_bps, dscr_target = interpolate_financing(ff)

    if structure_key == 'merchant':
        gearing = params['gearing']

    rev = build_revenue_series(structure_key, params)
    result = run_structure(STRUCTURE_LABELS[structure_key], rev, gearing, margin_bps, dscr_target, toll_tenor)
    return result


# ── 4. Chart functions ──────────────────────────────────────────────────────

def make_irr_chart(results_list):
    """IRR range chart for Compare tab. results_list: list of result dicts."""
    fig = go.Figure()

    for res in results_list:
        key = [k for k, v in STRUCTURE_LABELS.items() if v == res['name']][0]
        colour = STRUCTURE_COLOURS[key]
        low_irr = res['scenarios']['low']['irr']
        base_irr = res['scenarios']['base']['irr']
        high_irr = res['scenarios']['high']['irr']
        name = res['name']

        # Thin range bar
        fig.add_trace(go.Bar(
            x=[name], y=[high_irr - low_irr], base=[low_irr],
            marker_color='#d0d0d0', width=0.15,
            showlegend=False, hoverinfo='skip',
        ))
        # Base dot
        fig.add_trace(go.Scatter(
            x=[name], y=[base_irr],
            mode='markers+text', marker=dict(size=14, color=colour),
            text=[f'{base_irr:.1f}%'], textposition='middle right',
            textfont=dict(size=12, color=colour),
            showlegend=False,
            hovertemplate=f'<b>{name}</b><br>Base IRR: {base_irr:.1f}%<extra></extra>',
        ))
        # Low label
        fig.add_annotation(x=name, y=low_irr, text=f'{low_irr:.1f}%',
                           showarrow=False, font=dict(size=10, color=MID), yshift=-14)
        # High label
        fig.add_annotation(x=name, y=high_irr, text=f'{high_irr:.1f}%',
                           showarrow=False, font=dict(size=10, color=MID), yshift=14)

    # Hurdle line
    fig.add_hline(y=HURDLE_RATE, line_dash='dash', line_color=RED, line_width=1,
                  annotation_text='Hurdle', annotation_position='top left',
                  annotation_font=dict(size=10, color=RED))

    fig.update_layout(
        title=None,
        yaxis_title='Equity IRR (%)',
        plot_bgcolor='white', paper_bgcolor='white',
        yaxis=dict(gridcolor='#f0f0f0', zeroline=False),
        xaxis=dict(showgrid=False),
        margin=dict(l=50, r=30, t=20, b=40),
        height=350,
        font=dict(family='DM Sans, sans-serif'),
    )
    return fig


def make_dscr_chart(results_list):
    """DSCR profile chart for Compare tab. Shows base-case DSCR for each structure."""
    fig = go.Figure()
    years = list(range(1, SIZING_TENOR + 1))

    for res in results_list:
        key = [k for k, v in STRUCTURE_LABELS.items() if v == res['name']][0]
        colour = STRUCTURE_COLOURS[key]
        dscr = res['scenarios']['base']['dscr_series']
        min_idx = dscr.index(min(dscr))

        # Main DSCR line
        fig.add_trace(go.Scatter(
            x=years, y=dscr, name=res['name'],
            line=dict(color=colour, width=2.5),
            hovertemplate='Year %{x}: %{y:.2f}x<extra>' + res['name'] + '</extra>',
        ))
        # DSCR target dashed line
        fig.add_trace(go.Scatter(
            x=years, y=[res['dscr_target']] * len(years),
            line=dict(color=colour, width=1, dash='dash'),
            opacity=0.5, showlegend=False, hoverinfo='skip',
        ))
        # Min DSCR marker
        fig.add_trace(go.Scatter(
            x=[years[min_idx]], y=[dscr[min_idx]],
            mode='markers', marker=dict(symbol='diamond', size=10, color=colour),
            showlegend=False,
            hovertemplate=f'Min DSCR: {dscr[min_idx]:.2f}x (Year {years[min_idx]})<extra>{res["name"]}</extra>',
        ))

    # Breach zone
    fig.add_hrect(y0=0, y1=1.0, fillcolor='rgba(198,40,40,0.06)', line_width=0,
                  annotation_text='Covenant breach zone', annotation_position='bottom left',
                  annotation_font=dict(size=9, color=RED))

    fig.update_layout(
        title=None,
        xaxis_title='Year', yaxis_title='DSCR',
        plot_bgcolor='white', paper_bgcolor='white',
        yaxis=dict(gridcolor='#f0f0f0', zeroline=False),
        xaxis=dict(showgrid=False, dtick=1),
        margin=dict(l=50, r=30, t=20, b=40),
        height=350,
        legend=dict(orientation='h', yanchor='bottom', y=1.02, xanchor='left', x=0),
        font=dict(family='DM Sans, sans-serif'),
    )
    return fig


def make_revenue_chart(structure_key, params, scenario='base'):
    """Revenue composition stacked area chart for Explore tab."""
    fig = go.Figure()
    years = list(range(1, PROJECT_LIFE + 1))
    toll_tenor = params.get('toll_tenor', PROJECT_LIFE)

    if structure_key == 'merchant':
        rev = [REVENUE_TOTAL[scenario][i] for i in range(PROJECT_LIFE)]
        fig.add_trace(go.Scatter(
            x=years, y=rev, fill='tozeroy', name='Market revenue',
            line=dict(color=TEAL), fillcolor='rgba(26,122,110,0.3)',
        ))

    elif structure_key == 'full_toll':
        tolled = []
        merchant = []
        for i in range(PROJECT_LIFE):
            total = REVENUE_TOTAL[scenario][i]
            if i < toll_tenor:
                t = params['toll_price'] * (params['toll_pct'] / 100)
                m = total * (1 - params['toll_pct'] / 100)
            else:
                t = 0
                m = total
            tolled.append(t)
            merchant.append(m)

        fig.add_trace(go.Scatter(
            x=years, y=tolled, fill='tozeroy', name='Tolled portion',
            line=dict(color=TEAL), fillcolor='rgba(26,122,110,0.4)',
        ))
        fig.add_trace(go.Scatter(
            x=years, y=[tolled[i] + merchant[i] for i in range(PROJECT_LIFE)],
            fill='tonexty', name='Merchant portion',
            line=dict(color='#2196a8'), fillcolor='rgba(33,150,168,0.2)',
        ))
        fig.add_vline(x=toll_tenor + 0.5, line_dash='dash', line_color=MID, line_width=1,
                      annotation_text='Toll expiry', annotation_position='top left',
                      annotation_font=dict(size=9, color=MID))

    elif structure_key == 'floor_share':
        floor_band = []
        dev_band = []
        provider_band = []
        for i in range(PROJECT_LIFE):
            market = REVENUE_TOTAL[scenario][i]
            if i < toll_tenor:
                floor_guaranteed = params['floor_price'] * (params['floor_pct'] / 100)
                dev_rev = revenue_floor_share(i, scenario, params['floor_price'],
                                              params['floor_pct'], params['upside_share'],
                                              params['toll_tenor'])
                floor_band.append(floor_guaranteed)
                dev_band.append(dev_rev - floor_guaranteed)
                provider_band.append(market - dev_rev if market > dev_rev else 0)
            else:
                floor_band.append(0)
                dev_band.append(market)
                provider_band.append(0)

        fig.add_trace(go.Scatter(
            x=years, y=floor_band, fill='tozeroy', name='Floor guarantee',
            line=dict(color=TEAL), fillcolor='rgba(26,122,110,0.4)',
        ))
        cumul_dev = [floor_band[i] + dev_band[i] for i in range(PROJECT_LIFE)]
        fig.add_trace(go.Scatter(
            x=years, y=cumul_dev, fill='tonexty',
            name='Merchant above floor (developer)',
            line=dict(color='#2196a8'), fillcolor='rgba(33,150,168,0.2)',
        ))
        cumul_all = [cumul_dev[i] + provider_band[i] for i in range(PROJECT_LIFE)]
        fig.add_trace(go.Scatter(
            x=years, y=cumul_all, fill='tonexty', name='Share to provider',
            line=dict(color='#e57373'), fillcolor='rgba(229,115,115,0.15)',
        ))
        fig.add_vline(x=toll_tenor + 0.5, line_dash='dash', line_color=MID, line_width=1,
                      annotation_text='Toll expiry', annotation_position='top left',
                      annotation_font=dict(size=9, color=MID))

    elif structure_key == 'da_swap':
        da_fixed = []
        da_unhgd = []
        ancill = []
        for i in range(PROJECT_LIFE):
            da_actual = REVENUE_DA[scenario][i]
            anc = REVENUE_TOTAL[scenario][i] - da_actual
            if i < toll_tenor:
                df = params['da_fixed_leg'] * (params['da_swap_pct'] / 100)
                du = da_actual * (1 - params['da_swap_pct'] / 100)
            else:
                df = 0
                du = da_actual
            da_fixed.append(df)
            da_unhgd.append(du)
            ancill.append(anc)

        fig.add_trace(go.Scatter(
            x=years, y=da_fixed, fill='tozeroy', name='DA fixed leg',
            line=dict(color=TEAL), fillcolor='rgba(26,122,110,0.4)',
        ))
        c2 = [da_fixed[i] + da_unhgd[i] for i in range(PROJECT_LIFE)]
        fig.add_trace(go.Scatter(
            x=years, y=c2, fill='tonexty', name='DA unhedged',
            line=dict(color='#2196a8'), fillcolor='rgba(33,150,168,0.2)',
        ))
        c3 = [c2[i] + ancill[i] for i in range(PROJECT_LIFE)]
        fig.add_trace(go.Scatter(
            x=years, y=c3, fill='tonexty', name='Ancillary revenues',
            line=dict(color='#5c6bc0'), fillcolor='rgba(92,107,192,0.15)',
        ))
        fig.add_vline(x=toll_tenor + 0.5, line_dash='dash', line_color=MID, line_width=1,
                      annotation_text='Swap expiry', annotation_position='top left',
                      annotation_font=dict(size=9, color=MID))

    # Low/high overlay lines
    low_rev = [REVENUE_TOTAL['low'][i] for i in range(PROJECT_LIFE)]
    high_rev = [REVENUE_TOTAL['high'][i] for i in range(PROJECT_LIFE)]
    fig.add_trace(go.Scatter(
        x=years, y=low_rev, name='Low case total',
        line=dict(color='#bbb', width=1, dash='dash'), showlegend=True,
    ))
    fig.add_trace(go.Scatter(
        x=years, y=high_rev, name='High case total',
        line=dict(color='#bbb', width=1, dash='dot'), showlegend=True,
    ))

    fig.update_layout(
        title=None,
        xaxis_title='Year', yaxis_title='€k/MW/yr',
        plot_bgcolor='white', paper_bgcolor='white',
        yaxis=dict(gridcolor='#f0f0f0', zeroline=False),
        xaxis=dict(showgrid=False, dtick=1),
        margin=dict(l=50, r=30, t=20, b=40),
        height=350,
        legend=dict(orientation='h', yanchor='bottom', y=1.02, xanchor='left', x=0, font=dict(size=10)),
        font=dict(family='DM Sans, sans-serif'),
    )
    return fig


def make_cashflow_chart(result, toll_tenor):
    """Debt service vs revenue chart for Explore tab."""
    fig = go.Figure()
    years = list(range(1, PROJECT_LIFE + 1))

    base_rev = [result['scenarios']['base']['net_op'][i] + OPEX for i in range(PROJECT_LIFE)]
    ds = result['debt_service']
    equity_cf = [base_rev[i] - OPEX - ds[i] for i in range(PROJECT_LIFE)]

    # Shaded equity cash flow
    pos_y = [max(0, e) for e in equity_cf]
    neg_y = [min(0, e) for e in equity_cf]

    base_for_shade = [ds[i] + OPEX for i in range(PROJECT_LIFE)]
    fig.add_trace(go.Scatter(
        x=years, y=base_rev, name='Developer revenue (base)',
        line=dict(color=TEAL, width=3),
    ))
    fig.add_trace(go.Scatter(
        x=years, y=[ds[i] + OPEX for i in range(PROJECT_LIFE)],
        name='Debt service + OPEX', line=dict(color=RED, width=2),
        fill='tonexty',
        fillcolor='rgba(46,125,50,0.12)',
    ))

    # Mini-perm maturity line
    fig.add_vline(x=LOAN_TENOR + 0.5, line_dash='dash', line_color=MID, line_width=1,
                  annotation_text='Mini-perm maturity', annotation_position='top right',
                  annotation_font=dict(size=9, color=MID))

    # Toll expiry line (if different from loan tenor)
    if toll_tenor != LOAN_TENOR:
        fig.add_vline(x=toll_tenor + 0.5, line_dash='dash', line_color='#5c6bc0', line_width=1,
                      annotation_text='Toll expiry', annotation_position='top left',
                      annotation_font=dict(size=9, color='#5c6bc0'))

    fig.update_layout(
        title=None,
        xaxis_title='Year', yaxis_title='€k/MW/yr',
        plot_bgcolor='white', paper_bgcolor='white',
        yaxis=dict(gridcolor='#f0f0f0', zeroline=False),
        xaxis=dict(showgrid=False, dtick=1),
        margin=dict(l=50, r=30, t=20, b=40),
        height=350,
        legend=dict(orientation='h', yanchor='bottom', y=1.02, xanchor='left', x=0),
        font=dict(family='DM Sans, sans-serif'),
    )
    return fig


# ── 5. UI helper functions ──────────────────────────────────────────────────

def feasibility_badge(min_dscr, dscr_target):
    if min_dscr >= dscr_target:
        return 'pass', '&#10003; FEASIBLE'
    elif min_dscr >= dscr_target * 0.9:
        return 'warn', '&#9888; MARGINAL'
    else:
        return 'fail', '&#10007; NOT FEASIBLE'


def render_structure_card(result):
    badge_class, badge_text = feasibility_badge(
        result['scenarios']['low']['min_dscr'], result['dscr_target'])
    low_irr = result['scenarios']['low']['irr']
    base_irr = result['scenarios']['base']['irr']
    high_irr = result['scenarios']['high']['irr']
    min_d = result['scenarios']['low']['min_dscr']
    min_yr = result['scenarios']['low']['min_dscr_year']
    period = 'contracted' if result['scenarios']['low']['in_contracted'] else 'merchant'

    card_class = f'result-card result-card-{badge_class}'
    html = f"""
    <div class="{card_class}">
        <div style="font-size:1.1rem;font-weight:600;margin-bottom:8px;">{result['name']}</div>
        <div style="font-size:0.78rem;color:#666;margin-bottom:10px;">
            Gearing {result['gearing']:.0f}% &nbsp;&middot;&nbsp; Rate {result['all_in_rate']:.2f}% &nbsp;&middot;&nbsp; DSCR target {result['dscr_target']:.2f}x
        </div>
        <div class="section-header">EQUITY IRR</div>
        <div class="metric-large">{base_irr:.1f}%</div>
        <div style="font-size:0.82rem;color:#666;margin:4px 0 10px;">
            Low {low_irr:.1f}% &nbsp;&middot;&nbsp; High {high_irr:.1f}%
        </div>
        <div class="section-header">DEBT COVERAGE</div>
        <div style="font-size:0.9rem;margin-bottom:4px;">
            Min DSCR <b>{min_d:.2f}x</b> &nbsp;(Yr {min_yr}, {period})
        </div>
        <div class="feasibility-badge badge-{badge_class}">{badge_text}</div>
    </div>
    """
    st.markdown(html, unsafe_allow_html=True)


def render_results_panel(result):
    """Render IRR and DSCR cards for Explore tab."""
    col1, col2 = st.columns(2)

    base_irr = result['scenarios']['base']['irr']
    low_irr = result['scenarios']['low']['irr']
    high_irr = result['scenarios']['high']['irr']

    if base_irr > 10:
        irr_class = 'pass'
    elif base_irr >= 8:
        irr_class = 'warn'
    else:
        irr_class = 'fail'

    with col1:
        st.markdown(f"""
        <div class="result-card result-card-{irr_class}">
            <div class="section-header">EQUITY IRR</div>
            <div class="metric-large">{base_irr:.1f}%</div>
            <div style="font-size:0.82rem;color:#666;margin-top:6px;">
                Low &nbsp;{low_irr:.1f}%<br>
                High &nbsp;{high_irr:.1f}%<br>
                Hurdle &nbsp;{HURDLE_RATE:.1f}%
            </div>
        </div>
        """, unsafe_allow_html=True)

    min_d = result['scenarios']['low']['min_dscr']
    min_yr = result['scenarios']['low']['min_dscr_year']
    period = 'contracted' if result['scenarios']['low']['in_contracted'] else 'merchant'
    badge_class, badge_text = feasibility_badge(min_d, result['dscr_target'])

    with col2:
        st.markdown(f"""
        <div class="result-card result-card-{badge_class}">
            <div class="section-header">DEBT COVERAGE</div>
            <div class="metric-large">{min_d:.2f}x</div>
            <div style="font-size:0.82rem;color:#666;margin-top:6px;">
                Year &nbsp;{min_yr} ({period} period)<br>
                Target &nbsp;{result['dscr_target']:.2f}x
            </div>
            <div class="feasibility-badge badge-{badge_class}" style="margin-top:8px;">{badge_text}</div>
        </div>
        """, unsafe_allow_html=True)

    # Financing terms strip
    st.markdown(f"""
    <div class="terms-strip">
        Gearing {result['gearing']:.0f}% &nbsp;&middot;&nbsp;
        Rate {result['all_in_rate']:.2f}% &nbsp;&middot;&nbsp;
        Debt €{result['debt_k']:.0f}k/MW &nbsp;&middot;&nbsp;
        Equity €{result['equity_k']:.0f}k/MW
    </div>
    """, unsafe_allow_html=True)


def gearing_warning(user_gearing, recommended_gearing):
    if user_gearing > recommended_gearing + 5:
        return f"⚠️ {user_gearing}% exceeds the typical {recommended_gearing:.0f}% for this structure. Lenders are unlikely to support this without additional credit support."
    elif user_gearing < recommended_gearing - 10:
        return f"ℹ️ Conservative vs typical {recommended_gearing:.0f}% for this structure."
    return None


# ── 6. CSS ──────────────────────────────────────────────────────────────────

CSS = """
<style>
@import url('https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600&display=swap');

* { font-family: 'DM Sans', sans-serif; }

.result-card {
    background: white;
    border: 1px solid #e0e0e0;
    border-radius: 8px;
    padding: 16px 20px;
    margin-bottom: 12px;
}

.result-card-pass  { border-left: 4px solid #2e7d32; }
.result-card-warn  { border-left: 4px solid #e65100; }
.result-card-fail  { border-left: 4px solid #c62828; }

.metric-large {
    font-size: 2rem;
    font-weight: 600;
    color: #1a1a1a;
    line-height: 1.1;
}

.metric-label {
    font-size: 0.75rem;
    font-weight: 500;
    color: #666;
    text-transform: uppercase;
    letter-spacing: 0.05em;
}

.terms-strip {
    font-size: 0.8rem;
    color: #666;
    padding: 8px 0;
    border-top: 1px solid #f0f0f0;
    margin-top: 8px;
}

.feasibility-badge {
    display: inline-block;
    padding: 2px 10px;
    border-radius: 12px;
    font-size: 0.75rem;
    font-weight: 600;
}

.badge-pass { background: #e8f5e9; color: #2e7d32; }
.badge-warn { background: #fff3e0; color: #e65100; }
.badge-fail { background: #ffebee; color: #c62828; }

.disclaimer {
    background: #f5f5f5;
    border-left: 3px solid #ccc;
    padding: 10px 16px;
    font-size: 0.78rem;
    color: #888;
    border-radius: 4px;
    margin-bottom: 16px;
}

.section-header {
    font-size: 0.7rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: #1a7a6e;
    margin-bottom: 4px;
}
</style>
"""

DISCLAIMER = """
<div class="disclaimer">
Model for illustrative purposes only. Financing terms based on ABN AMRO project finance
presentation (Solarplaza, Cologne, December 2024). Revenue scenarios from Modo Energy
German BESS forecast. Not financial advice.
</div>
"""

FOOTER = """
<div style="text-align:center;margin-top:40px;padding:16px 0;border-top:1px solid #e0e0e0;font-size:0.75rem;color:#999;">
Modo Energy · German BESS Series · Article 4: Building Bankable Business Cases<br>
Revenue data: Modo Energy German BESS Forecast · Financing terms: ABN AMRO (Dec 2024)
</div>
"""


# ── 7. Main app ─────────────────────────────────────────────────────────────

def main():
    st.set_page_config(
        page_title="BESS Toll Structure Calculator",
        page_icon="⚡",
        layout="wide",
        initial_sidebar_state="collapsed",
    )

    st.markdown(CSS, unsafe_allow_html=True)

    # Header
    st.markdown("""
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px;">
        <div>
            <span style="font-size:1.6rem;font-weight:600;">⚡ German BESS Financing Structures</span>
        </div>
        <div style="font-size:0.85rem;color:#666;font-weight:500;">Modo Energy</div>
    </div>
    <div style="font-size:0.9rem;color:#888;margin-bottom:16px;">
        Compare four toll structures across revenue scenarios
    </div>
    """, unsafe_allow_html=True)

    tab_compare, tab_explore = st.tabs(["Compare All", "Explore Structure"])

    # ── COMPARE TAB ─────────────────────────────────────────────────────
    with tab_compare:
        st.markdown(DISCLAIMER, unsafe_allow_html=True)

        # Compute all 4 structures at defaults
        all_results = []
        for key in ['merchant', 'full_toll', 'floor_share', 'da_swap']:
            all_results.append(compute_structure_defaults(key))

        # 4 structure cards
        cols = st.columns(4)
        for i, res in enumerate(all_results):
            with cols[i]:
                render_structure_card(res)

        # IRR range chart
        st.markdown('<div class="section-header" style="margin-top:24px;">IRR RANGE COMPARISON</div>',
                    unsafe_allow_html=True)
        st.plotly_chart(make_irr_chart(all_results), use_container_width=True)

        # DSCR profile chart
        st.markdown('<div class="section-header" style="margin-top:16px;">DSCR PROFILE (BASE CASE)</div>',
                    unsafe_allow_html=True)
        st.plotly_chart(make_dscr_chart(all_results), use_container_width=True)

    # ── EXPLORE TAB ─────────────────────────────────────────────────────
    with tab_explore:
        st.markdown(DISCLAIMER, unsafe_allow_html=True)

        structure_choice = st.selectbox(
            'Select structure',
            ['Merchant', 'Full Toll', 'Floor + Share', 'Day-Ahead Swap'],
        )

        struct_map = {
            'Merchant': 'merchant',
            'Full Toll': 'full_toll',
            'Floor + Share': 'floor_share',
            'Day-Ahead Swap': 'da_swap',
        }
        struct_key = struct_map[structure_choice]

        left, right = st.columns([2, 3])

        with left:
            st.markdown('<div class="section-header">STRUCTURE INPUTS</div>', unsafe_allow_html=True)

            if struct_key == 'merchant':
                user_gearing = st.slider('Gearing %', 30, 55, 45, key='m_gear')
                guaranteed = 0
                ff = get_fixed_fraction(guaranteed)
                _, margin_bps, dscr_target = interpolate_financing(ff)
                gearing = user_gearing
                toll_tenor = PROJECT_LIFE
                params = {}

            elif struct_key == 'full_toll':
                toll_price = st.number_input('Toll price (€k/MW/yr)', 80, 140, 105, step=5, key='ft_price')
                toll_pct = st.slider('Contracted capacity %', 0, 100, 80, key='ft_pct')
                toll_tenor = st.slider('Toll tenor (years)', 3, 15, 7, key='ft_tenor')

                guaranteed = toll_price * (toll_pct / 100)
                ff = get_fixed_fraction(guaranteed)
                rec_gearing, margin_bps, dscr_target = interpolate_financing(ff)

                st.markdown(f'<div style="font-size:0.82rem;color:#666;">Recommended gearing: <b>{rec_gearing:.0f}%</b></div>',
                            unsafe_allow_html=True)
                user_gearing = st.slider('Gearing override %', 30, 85, int(round(rec_gearing)), key='ft_gear')
                gearing = user_gearing
                warn = gearing_warning(user_gearing, rec_gearing)
                if warn:
                    if warn.startswith('⚠'):
                        st.warning(warn)
                    else:
                        st.info(warn)
                params = {'toll_price': toll_price, 'toll_pct': toll_pct, 'toll_tenor': toll_tenor}

            elif struct_key == 'floor_share':
                floor_price = st.number_input('Floor level (€k/MW/yr)', 60, 120, 85, step=5, key='fs_floor')
                st.caption(f'ℹ Base case yr1: €{REVENUE_TOTAL["base"][0]}k  Low case yr1: €{REVENUE_TOTAL["low"][0]}k')
                floor_pct = st.slider('Protected capacity %', 0, 100, 80, key='fs_pct')
                upside_share = st.slider('Upside share to provider %', 0, 40, 20, key='fs_share')
                toll_tenor = st.slider('Toll tenor (years)', 3, 15, 7, key='fs_tenor')

                guaranteed = floor_price * (floor_pct / 100)
                ff = get_fixed_fraction(guaranteed)
                rec_gearing, margin_bps, dscr_target = interpolate_financing(ff)

                st.markdown(f'<div style="font-size:0.82rem;color:#666;">Recommended gearing: <b>{rec_gearing:.0f}%</b></div>',
                            unsafe_allow_html=True)
                user_gearing = st.slider('Gearing override %', 30, 85, int(round(rec_gearing)), key='fs_gear')
                gearing = user_gearing
                warn = gearing_warning(user_gearing, rec_gearing)
                if warn:
                    if warn.startswith('⚠'):
                        st.warning(warn)
                    else:
                        st.info(warn)
                params = {'floor_price': floor_price, 'floor_pct': floor_pct,
                          'upside_share': upside_share, 'toll_tenor': toll_tenor}

            elif struct_key == 'da_swap':
                da_fixed_leg = st.number_input('DA fixed leg (€k/MW/yr)', 30, 70, 45, step=5, key='da_leg')
                st.caption(f'ℹ Base case yr1 DA revenue: €{REVENUE_DA["base"][0]}k/MW  Low case: €{REVENUE_DA["low"][0]}k/MW')
                da_swap_pct = st.slider('DA capacity covered %', 0, 100, 100, key='da_pct')
                toll_tenor = st.slider('Swap tenor (years)', 3, 15, 10, key='da_tenor')

                guaranteed = da_fixed_leg * (da_swap_pct / 100)
                ff = get_fixed_fraction(guaranteed)
                rec_gearing, margin_bps, dscr_target = interpolate_financing(ff)

                st.markdown(f'<div style="font-size:0.82rem;color:#666;">Recommended gearing: <b>{rec_gearing:.0f}%</b></div>',
                            unsafe_allow_html=True)
                user_gearing = st.slider('Gearing override %', 30, 85, int(round(rec_gearing)), key='da_gear')
                gearing = user_gearing
                warn = gearing_warning(user_gearing, rec_gearing)
                if warn:
                    if warn.startswith('⚠'):
                        st.warning(warn)
                    else:
                        st.info(warn)
                params = {'da_fixed_leg': da_fixed_leg, 'da_swap_pct': da_swap_pct, 'toll_tenor': toll_tenor}

        # Compute results
        rev_series = build_revenue_series(struct_key, params) if struct_key != 'merchant' else build_revenue_series('merchant', {})
        result = run_structure(structure_choice, rev_series, gearing, margin_bps, dscr_target, toll_tenor)

        with right:
            render_results_panel(result)

            st.markdown('<div class="section-header" style="margin-top:20px;">REVENUE COMPOSITION (BASE CASE)</div>',
                        unsafe_allow_html=True)
            st.plotly_chart(make_revenue_chart(struct_key, params), use_container_width=True)

            st.markdown('<div class="section-header" style="margin-top:12px;">DEBT SERVICE VS REVENUE</div>',
                        unsafe_allow_html=True)
            st.plotly_chart(make_cashflow_chart(result, toll_tenor), use_container_width=True)

    # Footer
    st.markdown(FOOTER, unsafe_allow_html=True)


# ── 8. Entry point ──────────────────────────────────────────────────────────

if __name__ == '__main__':
    main()
