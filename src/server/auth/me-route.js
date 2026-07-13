const { createSupabaseAccountDataSource } = require('./account-data');

function createMeHandler({ accountDataSource = createSupabaseAccountDataSource(), logger = console } = {}) {
  return async function getMe(req, res) {
    try {
      const account = await accountDataSource.getAccount({
        userId: req.auth.userId,
        accessToken: req.auth.accessToken
      });
      if (!account) {
        return res.status(409).json({
          error: {
            code: 'profile_initializing',
            message: '账户资料正在初始化，请稍后重试。'
          }
        });
      }
      return res.json({
        user: {
          id: account.profile.id,
          email: account.profile.email || req.auth.email || null,
          displayName: account.profile.display_name || null
        },
        households: account.households
      });
    } catch (error) {
      if (process.env.NODE_ENV !== 'production') {
        logger.error(
          `[auth/me] account lookup failed: code=${error?.code || 'unknown'} type=${error?.name || 'Error'}`
        );
      }
      return res.status(503).json({
        error: {
          code: 'account_unavailable',
          message: '暂时无法读取账户资料，请稍后重试。'
        }
      });
    }
  };
}

module.exports = { createMeHandler };
